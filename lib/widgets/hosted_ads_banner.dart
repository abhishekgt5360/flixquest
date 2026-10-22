import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../models/banner_ad.dart';
import '../provider/app_dependency_provider.dart';
import '../services/hosted_ads_repository.dart';
import '../services/device_presentation_service.dart';
import 'network_banner_widget.dart';

final CacheManager _adImageCache = CacheManager(
  Config(
    'flixquest_ad_images',
    stalePeriod: const Duration(minutes: 15),
    maxNrOfCacheObjects: 24,
  ),
);

enum HostedBannerVariant {
  standard,
  tall;

  bool get isTall => this == HostedBannerVariant.tall;
}

/// One banner slot shared by the two ad sources.
///
/// The hosted `/ads` banner (announcements and calls to action from our own
/// backend) and the ad network's banner are independent: each has its own
/// switch and either can be live without the other. `banner_ad_network`
/// picks the network (Adsterra, Clickadu or ExoClick), with optional per-slot
/// `banner_ad_network_overrides`. [HostedBannerMode] decides what
/// happens when both are live in the same slot. A remotely configured
/// `banner_ad_network=none` still hides everything.
class RemoteHostedAdsBanner extends StatefulWidget {
  const RemoteHostedAdsBanner({
    required this.placement,
    this.loadAds,
    this.variant = HostedBannerVariant.standard,
    this.padding = const EdgeInsets.fromLTRB(20, 14, 20, 6),
    super.key,
  });

  /// Replaces the shared `/ads` loader; used by tests.
  final Future<List<BannerAd>> Function()? loadAds;
  final String placement;
  final HostedBannerVariant variant;
  final EdgeInsetsGeometry padding;

  @override
  State<RemoteHostedAdsBanner> createState() => _RemoteHostedAdsBannerState();
}

class _RemoteHostedAdsBannerState extends State<RemoteHostedAdsBanner> {
  Future<List<BannerAd>>? _ads;

  Future<List<BannerAd>> _load(AppDependencyProvider dependencies) =>
      widget.loadAds?.call() ??
      HostedAdsRepository.instance.load(dependencies.flixquestAPIURL);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  /// Keeps the network banner close under a hosted banner it shares a slot
  /// with, instead of doubling the gap.
  EdgeInsetsGeometry _tucked(EdgeInsetsGeometry padding) =>
      padding.resolve(Directionality.of(context)).copyWith(top: 6);

  Widget _network(
    AppDependencyProvider dependencies,
    EdgeInsetsGeometry padding,
  ) {
    final television = DevicePresentationService.instance.isTelevision;
    final ads = dependencies.bannerAdsForPlacement(widget.placement,
        television: television);
    if (ads == null || !NetworkBannerWidget.isSupported) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(builder: (context, constraints) {
      final insets = padding.resolve(Directionality.of(context));
      final unit = ads.resolve(
        widget.placement,
        tall: widget.variant.isTall,
        television: television,
        maxWidth: constraints.maxWidth - insets.horizontal,
        maxHeight: constraints.maxHeight - insets.vertical - 18,
      );
      if (unit == null) return const SizedBox.shrink();
      return NetworkBannerWidget(
        key: ValueKey((widget.placement, unit, television)),
        placement: widget.placement,
        unit: unit,
        television: television,
        padding: padding,
      );
    });
  }
}

/// A banner for surfaces that never passed their own ad loader: the stream
/// loader, Live TV and the TV details page.
class BannerAdSlot extends StatelessWidget {
  const BannerAdSlot({
    required this.placement,
    this.variant = HostedBannerVariant.tall,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final String placement;
  final HostedBannerVariant variant;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => RemoteHostedAdsBanner(
        placement: placement,
        variant: variant,
        padding: padding,
      );
}

/// The hosted announcement / call-to-action banner served by `/ads`.
class HostedAdsBanner extends StatelessWidget {
  const HostedAdsBanner({
    required this.ads,
    this.variant = HostedBannerVariant.standard,
    this.interactive = true,
    this.padding = const EdgeInsets.fromLTRB(20, 14, 20, 6),
    super.key,
  });

  final List<BannerAd> ads;
  final HostedBannerVariant variant;

  /// The widest a banner grows, so a tablet doesn't stretch it edge to edge.
  static const _maxWidth = 640.0;

  /// Android TV's quality rules forbid an in-page ad that opens a web page, so
  /// TV shows the banner without a tap target or D-pad focus.
  final bool interactive;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Reads the ad image's own width-to-height ratio, so a banner sized from it
/// shows the whole image. Until the image loads, [fallback] stands in.
class _AdImageRatio extends StatefulWidget {
  const _AdImageRatio({
    required this.imageUrl,
    required this.fallback,
    required this.builder,
  });

  final String imageUrl;
  final double fallback;
  final Widget Function(BuildContext context, double ratio) builder;

  @override
  State<_AdImageRatio> createState() => _AdImageRatioState();
}

class _AdImageRatioState extends State<_AdImageRatio> {
  late final ImageStreamListener _listener =
      ImageStreamListener(_onImage, onError: (_, __) {});
  ImageStream? _stream;
  double? _ratio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_AdImageRatio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl == widget.imageUrl) return;
    _ratio = null;
    _resolve();
  }

  void _resolve() {
    final stream = CachedNetworkImageProvider(
      widget.imageUrl,
      cacheManager: _adImageCache,
    ).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool _) {
    final image = info.image;
    final ratio = image.height == 0 ? null : image.width / image.height;
    info.dispose();
    if (ratio == null || ratio == _ratio) return;
    setState(() => _ratio = ratio);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _ratio ?? widget.fallback);
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
  try {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    // A broken link must not surface as an error on a browsing screen.
  }
}

class _CachedAdCarousel extends StatefulWidget {
  const _CachedAdCarousel({
    required this.ads,
    required this.width,
    required this.height,
    required this.interactive,
  });

  final List<BannerAd> ads;
  final double width;
  final double height;
  final bool interactive;

  @override
  State<_CachedAdCarousel> createState() => _CachedAdCarouselState();
}

class _CachedAdCarouselState extends State<_CachedAdCarousel> {
  final PageController _controller = PageController();
  Timer? _rotationTimer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (widget.ads.length > 1) {
      _rotationTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!mounted) return;
        _index = (_index + 1) % widget.ads.length;
        _controller.animateToPage(
          _index,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.ads.length,
        onPageChanged: (index) => _index = index,
        itemBuilder: (context, index) {
          final ad = widget.ads[index];
          return GestureDetector(
            onTap: widget.interactive
                ? () => unawaited(_open(ad.targetUrl))
                : null,
            child: Semantics(
              label: ad.altText.isEmpty ? ad.name : ad.altText,
              image: true,
              child: CachedNetworkImage(
                imageUrl: ad.imageUrl,
                cacheManager: _adImageCache,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          );
        },
      ),
    );
  }
}
