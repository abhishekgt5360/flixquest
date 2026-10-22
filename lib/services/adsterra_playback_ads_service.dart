import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/adsterra_playback_ads_config.dart';
import '../provider/app_dependency_provider.dart';
import '../widgets/ad_block_gate.dart';
import '../widgets/adsterra_playback_ad_screen.dart';
import 'device_presentation_service.dart';
import 'playback_ad_input_service.dart';
import 'playback_ad_browser_service.dart';

export '../widgets/adsterra_playback_ad_screen.dart' show PlaybackAdPreload;

/// One coordinator for every playback entry point, phone and TV. Skipped or
/// failed ads continue immediately; an overlapping request never starts
/// another loader. TV shows only a stream-found `tv_popunder`, from its own
/// network and interval. Phones may also show popups for the triggers in
/// [PlaybackAdStage.triggers], each with its own switch and interval.
class AdsterraPlaybackAdsService {
  AdsterraPlaybackAdsService({
    Future<SharedPreferences> Function()? preferences,
    this.storeLauncher,
    this.browserLauncher,
    this.continueTap,
    DateTime Function()? now,
  })  : _preferences = preferences ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;
  static final instance = AdsterraPlaybackAdsService();
  static String _lastPopupShownKey(PlaybackAdStage stage) =>
      stage == PlaybackAdStage.streamFound
          ? 'playback_ads.last_popup_shown_at'
          : 'playback_ads.last_${stage.triggerKey}_popup_shown_at';

  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _now;
  final StoreLauncher? storeLauncher;
  final PlaybackBrowserLauncher? browserLauncher;
  final PlaybackContinueTap? continueTap;
  final Map<String, int> _rotation = {};
  final Map<PlaybackAdStage, DateTime> _lastPopupShownAt = {};

  /// When a player-exit popup was earned and not yet settled. Saved on the
  /// device as soon as it is earned, so closing the app from the player
  /// instead of leaving it still owes the popup on the next launch.
  static const _owedPlayerExitKey = 'playback_ads.player_exit_owed_at';
  bool _playerExitOwed = false;
  bool _launchChecked = false;

  /// How long the next launch waits for the stored Remote Config before
  /// leaving an owed popup for a later launch.
  static const owedPopupConfigWait = Duration(seconds: 5);
  bool _busy = false;

  /// Lets route builders omit the waiting frame when no interstitial can run.
  bool needsBeforeLoader(BuildContext context, {bool television = false}) =>
      false;

  bool _eligible(BuildContext context,
      {bool download = false, bool television = false}) => false;

  /// The ad blocker check runs first, so a blocked viewer is not kept
  /// waiting on an interstitial that cannot load.
  Future<bool> beforeLoader(BuildContext context,
      {bool download = false, bool television = false}) async => true;

  /// A loader the player itself started passes [PlaybackAdStage.episodeSwitch]
  /// or [PlaybackAdStage.movieSwitch] as [stage].
  Future<bool> streamFound(BuildContext context,
          {bool download = false,
          bool television = false,
          PlaybackAdPreload? preload,
          PlaybackAdStage stage = PlaybackAdStage.streamFound}) async => true;

  /// Call from a phone player just before it pops itself.
  void afterPlayerExit(BuildContext playerContext,
          {required Duration watched}) {}

  /// Call from a loader that queued a download, just before it pops itself.
  void afterDownloadQueued(BuildContext loaderContext) {}

  /// The popup opens over the screen the viewer returns to once the route
  /// around [routeContext] has gone, so Back itself is never held.
  void _afterRouteGone(BuildContext routeContext,
      Future<void> Function(BuildContext context) present) {
    final navigator = Navigator.of(routeContext);
    final route = ModalRoute.of(routeContext);
    void showPopup() {
      if (navigator.mounted) unawaited(present(navigator.context));
    }

    if (route == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => showPopup());
      return;
    }
    // `completed` resolves as the pop starts; wait out the exit transition.
    unawaited(route.completed.then((_) {
      final animation = route.animation;
      if (animation == null || animation.isDismissed) return showPopup();
      void onStatus(AnimationStatus status) {
        if (status != AnimationStatus.dismissed) return;
        animation.removeStatusListener(onStatus);
        showPopup();
      }

      animation.addStatusListener(onStatus);
    }));
  }

  /// After the viewer leaves the player, once its route has popped. Only a
  /// real watch counts: an exit after a failed or bounced stream shows nothing.
  Future<void> playerExit(BuildContext context,
      {required Duration watched}) async {}

  /// Players report their content watch time as it grows.
  void notePlayerWatch(BuildContext context, Duration watched) {}

  /// On launch, once the first screen is up: opens a player-exit popup owed.
  Future<void> showOwedPlayerExitOnLaunch(BuildContext context) async {}

  /// Settles the owed popup once the attempt finishes in the app: shown,
  /// skipped by its switch or interval, or unfilled. An attempt cut short by
  /// navigation, another ad or the app closing leaves it owed.
  Future<void> _showOwedPlayerExit(BuildContext context) async {
    if (await show(context, PlaybackAdStage.playerExit)) {
      await _settleOwedPlayerExit();
    }
  }

  Future<bool> _configApplied(AppDependencyProvider provider) async {
    if (provider.remoteConfigApplied) return true;
    final applied = Completer<bool>();
    void onChanged() {
      if (provider.remoteConfigApplied && !applied.isCompleted) {
        applied.complete(true);
      }
    }

    provider.addListener(onChanged);
    final timer = Timer(owedPopupConfigWait, () {
      if (!applied.isCompleted) applied.complete(false);
    });
    try {
      return await applied.future;
    } finally {
      timer.cancel();
      provider.removeListener(onChanged);
    }
  }

  Future<void> _writeOwedPlayerExit(DateTime owedAt) async {
    try {
      final preferences = await _preferences();
      if (!await preferences.setInt(
          _owedPlayerExitKey, owedAt.millisecondsSinceEpoch)) {
        debugPrint('[AdsterraPlayback] owed popup persistence unavailable');
      }
    } catch (error) {
      debugPrint('[AdsterraPlayback] owed popup persistence failed ($error)');
    }
  }

  Future<void> _settleOwedPlayerExit() async {
    _playerExitOwed = false;
    try {
      await (await _preferences()).remove(_owedPlayerExitKey);
    } catch (error) {
      debugPrint('[AdsterraPlayback] owed popup not cleared ($error)');
    }
  }

  /// Prepare an empty WebView while sources load, for any network or format.
  /// Ad requests and activation wait for the visible ad screen. Experiments
  /// keep selecting their arm at presentation, so cancelled lookups do not
  /// advance rotation.
  PlaybackAdPreload? preloadStreamFound(BuildContext context,
      {bool download = false,
      bool television = false,
      PlaybackAdStage stage = PlaybackAdStage.streamFound}) =>
      null;

  Future<bool> show(BuildContext context, PlaybackAdStage requested,
      {bool download = false,
      bool television = false,
      PlaybackAdPreload? preload}) async =>
      true;

  /// Episode and movie switches keep the stream-found popup on TV, and on
  /// phones until their own switch is published.
  PlaybackAdStage _resolveStage(
          AppDependencyProvider? provider, PlaybackAdStage stage, bool tv) =>
      stage.isSwitch && (tv || provider?.popupTrigger(stage) == null)
          ? PlaybackAdStage.streamFound
          : stage;

  PlaybackAdPlacement? _placementFor(AppDependencyProvider provider,
      PlaybackAdStage stage, AdNetwork? network, bool tv) {
    if (stage.triggerKey != null &&
        provider.popupTrigger(stage)?.enabled != true) {
      return null;
    }
    final selection = provider.playbackAdsSelection;
    return switch (network) {
      AdNetwork.adsterra => selection.adsterra.forStage(stage, television: tv),
      AdNetwork.clickadu ||
      AdNetwork.monetag ||
      AdNetwork.exoclick =>
        stage == PlaybackAdStage.streamFound
            ? selection.popunders[network]?.activeFor(television: tv)
            : selection.popunders[network]?.activeForTrigger(stage),
      null => null,
    };
  }

  int _frequencyFor(
      AppDependencyProvider provider, PlaybackAdStage stage, bool tv) {
    if (stage.triggerKey != null) {
      return provider.popupTrigger(stage)?.frequencyMinutes ?? 0;
    }
    final selection = provider.playbackAdsSelection;
    return tv
        ? selection.tvPopupFrequencyMinutes
        : selection.popupFrequencyMinutes;
  }

  bool _popupCoolingDown(PlaybackAdStage stage, int minutes) {
    final lastShown = _lastPopupShownAt[stage];
    if (minutes <= 0 || lastShown == null) return false;
    final elapsed = _now().difference(lastShown);
    // A clock correction must not leave the viewer capped by a future date.
    return !elapsed.isNegative && elapsed.inMinutes < minutes;
  }

  Future<void> _loadPopupHistory(PlaybackAdStage stage) async {
    try {
      final preferences = await _preferences();
      final timestamp = preferences.getInt(_lastPopupShownKey(stage));
      if (timestamp == null || timestamp <= 0) return;
      final persisted = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (persisted.isAfter(_now())) return;
      final known = _lastPopupShownAt[stage];
      if (known == null || persisted.isAfter(known)) {
        _lastPopupShownAt[stage] = persisted;
      }
    } catch (error) {
      debugPrint(
          '[AdsterraPlayback] popup frequency uses session storage ($error)');
    }
  }

  Future<void> _recordPopupShown(PlaybackAdStage stage) async {
    final shownAt = _now();
    _lastPopupShownAt[stage] = shownAt;
    try {
      final preferences = await _preferences();
      if (!await preferences.setInt(
          _lastPopupShownKey(stage), shownAt.millisecondsSinceEpoch)) {
        debugPrint(
            '[AdsterraPlayback] popup frequency persistence unavailable');
      }
    } catch (error) {
      debugPrint(
          '[AdsterraPlayback] popup frequency uses session storage ($error)');
    }
  }

  Future<PlaybackAdVariant> _nextVariant(
      PlaybackAdExperiment experiment) async {
    final key = 'adsterra_playback.rotation.${experiment.id}';
    var index = _rotation[key] ?? 0;
    try {
      final preferences = await _preferences();
      index = preferences.getInt(key) ?? index;
      index = index % experiment.variants.length;
      final next = (index + 1) % experiment.variants.length;
      _rotation[key] = next;
      if (!await preferences.setInt(key, next)) {
        debugPrint('[AdsterraPlayback] rotation persistence unavailable');
      }
    } catch (error) {
      index = index % experiment.variants.length;
      _rotation[key] = (index + 1) % experiment.variants.length;
      debugPrint('[AdsterraPlayback] rotation uses session storage ($error)');
    }
    return experiment.variants[index];
  }

  void _logSkip(PlaybackAdStage stage, String reason) {
    debugPrint('[AdsterraPlayback] ${stage.name}: skipped ($reason)');
  }
}

Future<bool> _waitForForeground() async {
  final state = WidgetsBinding.instance.lifecycleState;
  if (state == null || state == AppLifecycleState.resumed) return true;
  if (state == AppLifecycleState.detached) return false;
  final waiter = _PlaybackForegroundWaiter();
  WidgetsBinding.instance.addObserver(waiter);
  try {
    return await waiter.result.future;
  } finally {
    WidgetsBinding.instance.removeObserver(waiter);
  }
}

class _PlaybackForegroundWaiter extends WidgetsBindingObserver {
  final result = Completer<bool>();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!result.isCompleted &&
        (state == AppLifecycleState.resumed ||
            state == AppLifecycleState.detached)) {
      result.complete(state == AppLifecycleState.resumed);
    }
  }
}
