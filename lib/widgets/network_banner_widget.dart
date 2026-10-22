import 'package:flutter/material.dart';

import '../models/banner_ads_config.dart';

/// One WebView per visible banner, from whichever network serves the slot.
/// Config/size changes replace the view, while ordinary parent rebuilds keep
/// it loaded. There is no automatic refresh.
class NetworkBannerWidget extends StatefulWidget {
  // Android's reserved app-content host gives local HTML a non-opaque origin
  // so scripts can use document.cookie/storage without adopting an ad server
  // or publisher website's origin. No request is made to this base URL.
  static const documentBaseUrl =
      'https://appassets.androidplatform.net/adsterra/';

  const NetworkBannerWidget({
    required this.placement,
    required this.unit,
    this.television = false,
    this.padding = const EdgeInsets.fromLTRB(20, 14, 20, 6),
    super.key,
  });

  final String placement;
  final BannerAdUnit unit;
  final bool television;
  final EdgeInsetsGeometry padding;

  static bool get isSupported => false;

  @override
  State<NetworkBannerWidget> createState() => _NetworkBannerWidgetState();
}

class _NetworkBannerWidgetState extends State<NetworkBannerWidget> {
  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
