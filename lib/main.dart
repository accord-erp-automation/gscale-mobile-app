import 'dart:async';
import 'dart:convert';

import 'package:device_preview/device_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'network_candidates_stub.dart'
    if (dart.library.io) 'network_candidates_io.dart'
    as network_candidates;

const _defaultApiPort = 8081;
const _discoveryPort = 18081;
const _fastProbeTimeout = Duration(milliseconds: 180);
const _manualProbeTimeout = Duration(seconds: 2);
const _udpDiscoveryTimeout = Duration(milliseconds: 450);
const _fallbackProbeTimeout = Duration(milliseconds: 240);
const _fallbackProbeConcurrency = 24;
const _lastServerKey = 'last_server_base_url';
const _defaultWifiServerAddress = 'http://gscale.local:8081';
const _configuredApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: _defaultWifiServerAddress,
);
const _m3Surface = Color(0xFFF4EEFF);
const _m3Container = Color(0xFFDCD6F7);
const _m3Accent = Color(0xFFA6B1E1);
const _m3Primary = Color(0xFF424874);

bool get previewEnabled {
  if (kReleaseMode) {
    return false;
  }
  if (kIsWeb) {
    return true;
  }

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return false;
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return true;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (previewEnabled) {
    runApp(
      DevicePreview(
        enabled: true,
        isToolbarVisible: true,
        tools: const [...DevicePreview.defaultTools],
        builder: (context) => const GScaleMobileApp(),
      ),
    );
    return;
  }
  runApp(const GScaleMobileApp());
}

class GScaleMobileApp extends StatefulWidget {
  const GScaleMobileApp({super.key});

  @override
  State<GScaleMobileApp> createState() => _GScaleMobileAppState();
}

class _GScaleMobileAppState extends State<GScaleMobileApp> {
  DiscoveredServer? _selectedServer;

  Future<void> _openServer(DiscoveredServer server) async {
    await saveLastUsedServer(server.endpoint);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedServer = server;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GScale Mobile',
      debugShowCheckedModeBanner: false,
      locale: previewEnabled ? DevicePreview.locale(context) : null,
      builder: previewEnabled ? DevicePreview.appBuilder : null,
      themeMode: ThemeMode.system,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: _selectedServer == null
          ? ServerPickerPage(onOpenServer: _openServer)
          : OperatorDashboardPage(
              server: _selectedServer!,
              onChangeServer: () {
                setState(() {
                  _selectedServer = null;
                });
              },
            ),
    );
  }
}

ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final seedScheme = ColorScheme.fromSeed(
    seedColor: _m3Primary,
    brightness: brightness,
  );
  final scheme = isDark
      ? seedScheme
      : seedScheme.copyWith(
          primary: _m3Primary,
          onPrimary: _m3Surface,
          primaryContainer: _m3Container,
          onPrimaryContainer: _m3Primary,
          secondary: _m3Accent,
          onSecondary: _m3Primary,
          secondaryContainer: _m3Container,
          onSecondaryContainer: _m3Primary,
          tertiary: _m3Accent,
          onTertiary: _m3Primary,
          tertiaryContainer: _m3Container,
          onTertiaryContainer: _m3Primary,
          surface: _m3Surface,
          onSurface: _m3Primary,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: _m3Surface,
          surfaceContainer: _m3Container.withValues(alpha: 0.38),
          surfaceContainerHigh: _m3Container.withValues(alpha: 0.54),
          surfaceContainerHighest: _m3Container.withValues(alpha: 0.72),
          outline: _m3Accent,
          outlineVariant: _m3Container,
          error: const Color(0xFFB3261E),
          onError: Colors.white,
        );
  final baseTextTheme = isDark
      ? Typography.material2021().white
      : Typography.material2021().black;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.65),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    textTheme: baseTextTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
  );
}

class ServerPickerPage extends StatefulWidget {
  const ServerPickerPage({required this.onOpenServer, super.key});

  final ValueChanged<DiscoveredServer> onOpenServer;

  @override
  State<ServerPickerPage> createState() => _ServerPickerPageState();
}

class _ServerPickerPageState extends State<ServerPickerPage> {
  final http.Client _client = http.Client();

  bool _scanning = false;
  DiscoveryResult? _result;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_scan());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_scanning) {
      return;
    }

    setState(() {
      _scanning = true;
    });

    try {
      final preferredEndpoint = await loadLastUsedServer();
      final result = await discoverServers(
        _client,
        preferredEndpoint: preferredEndpoint,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _result = result;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _result ??= const DiscoveryResult(
          servers: <DiscoveredServer>[],
          candidateCount: 0,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<void> _openManualEntrySheet() async {
    final server = await showModalBottomSheet<DiscoveredServer>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ManualServerSheet(client: _client),
    );
    if (server == null || !mounted) {
      return;
    }
    widget.onOpenServer(server);
  }

  @override
  Widget build(BuildContext context) {
    final servers = _result?.servers ?? const <DiscoveredServer>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('gscale-zebra'),
        actions: [
          IconButton(
            onPressed: _openManualEntrySheet,
            icon: const Icon(Icons.add_link_rounded),
            tooltip: 'Add',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _scan,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: [
            if (_scanning && servers.isEmpty) const _ScanningState(),
            if (!_scanning && servers.isEmpty)
              _EmptyServerState(onManualAdd: _openManualEntrySheet),
            if (servers.isNotEmpty)
              _ServerList(servers: servers, onOpenServer: widget.onOpenServer),
          ],
        ),
      ),
    );
  }
}

class OperatorDashboardPage extends StatefulWidget {
  const OperatorDashboardPage({
    required this.server,
    required this.onChangeServer,
    super.key,
  });

  final DiscoveredServer server;
  final VoidCallback onChangeServer;

  @override
  State<OperatorDashboardPage> createState() => _OperatorDashboardPageState();
}

class _OperatorDashboardPageState extends State<OperatorDashboardPage> {
  final http.Client _client = http.Client();
  final TextEditingController _itemSearchController = TextEditingController();
  final TextEditingController _warehouseSearchController =
      TextEditingController();
  StreamSubscription<String>? _streamSubscription;
  int _streamGeneration = 0;
  int _selectedSection = 0;
  Timer? _itemSearchDebounce;
  Timer? _warehouseSearchDebounce;

  bool _manualLoading = false;
  bool _requestInFlight = false;
  bool _itemsLoading = false;
  bool _warehousesLoading = false;
  bool _batchActionLoading = false;
  bool _connected = false;
  String _statusText = 'idle';
  String _errorText = '';
  String _itemsError = '';
  String _warehousesError = '';
  MonitorSnapshot _snapshot = MonitorSnapshot.empty();
  List<MobileItem> _items = const [];
  List<MobileWarehouse> _warehouses = const [];
  MobileItem? _selectedItem;
  MobileWarehouse? _selectedWarehouse;
  Timer? _pingTimer;

  @override
  void initState() {
    super.initState();
    _itemSearchController.addListener(_scheduleItemSearch);
    _warehouseSearchController.addListener(_scheduleWarehouseSearch);
    _snapshot = MonitorSnapshot.empty().copyWithLatency(
      widget.server.latencyMs,
    );
    _startLiveStream();
    _startPingLoop();
    unawaited(_loadItems());
  }

  @override
  void dispose() {
    _itemSearchDebounce?.cancel();
    _warehouseSearchDebounce?.cancel();
    _pingTimer?.cancel();
    _itemSearchController.dispose();
    _warehouseSearchController.dispose();
    _stopLiveStream();
    _client.close();
    super.dispose();
  }

  void _startLiveStream() {
    _streamGeneration++;
    final generation = _streamGeneration;
    unawaited(_runLiveStream(generation));
  }

  void _startPingLoop() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refreshLatency());
    });
    unawaited(_refreshLatency());
  }

  void _stopLiveStream() {
    _streamGeneration++;
    unawaited(_streamSubscription?.cancel());
    _streamSubscription = null;
  }

  Future<void> _refreshLatency() async {
    if (!mounted) {
      return;
    }

    final server = widget.server;
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client
          .get(Uri.parse('${server.endpoint.baseUrl}/healthz'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode < 200 || response.statusCode > 299) {
        return;
      }
      stopwatch.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = _snapshot.copyWithLatency(stopwatch.elapsedMilliseconds);
        _connected = true;
      });
    } catch (_) {
      return;
    }
  }

  Future<void> _runLiveStream(int generation) async {
    while (mounted && generation == _streamGeneration) {
      try {
        if (mounted) {
          setState(() {
            _statusText = _connected ? 'reconnecting' : 'connecting';
          });
        }
        await _connectLiveStreamOnce(generation);
      } catch (error) {
        if (!mounted || generation != _streamGeneration) {
          return;
        }
        setState(() {
          _connected = false;
          _statusText = 'offline';
          _errorText = error.toString();
        });
      }

      if (!mounted || generation != _streamGeneration) {
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _connectLiveStreamOnce(int generation) async {
    final request = http.Request(
      'GET',
      Uri.parse('${widget.server.endpoint.baseUrl}/v1/mobile/monitor/stream'),
    );
    request.headers['Accept'] = 'text/event-stream';

    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 4));
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw Exception('stream ${response.statusCode}');
    }

    final completer = Completer<void>();
    final dataLines = <String>[];

    await _streamSubscription?.cancel();
    _streamSubscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!mounted || generation != _streamGeneration) {
              return;
            }
            if (line.isEmpty) {
              if (dataLines.isEmpty) {
                return;
              }
              final payloadText = dataLines.join('\n');
              dataLines.clear();
              final payload = jsonDecode(payloadText) as Map<String, dynamic>;
              if (payload.containsKey('error') && payload['ok'] != true) {
                setState(() {
                  _connected = false;
                  _statusText = 'offline';
                  _errorText = payload['error'].toString();
                });
                return;
              }
              setState(() {
                _applySnapshot(MonitorSnapshot.fromJson(payload));
                _connected = true;
                _statusText = 'live';
                _errorText = '';
              });
              return;
            }
            if (line.startsWith(':')) {
              return;
            }
            if (line.startsWith('data:')) {
              dataLines.add(line.substring(5).trimLeft());
            }
          },
          onError: (error, _) {
            if (!completer.isCompleted) {
              completer.completeError(error);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          cancelOnError: true,
        );

    await completer.future;
  }

  Future<void> _refresh({bool manual = false}) async {
    if (_requestInFlight) {
      return;
    }

    _requestInFlight = true;
    if (manual && mounted) {
      setState(() {
        _manualLoading = true;
        _errorText = '';
        _statusText = 'refreshing';
      });
    }

    try {
      final health = await _client
          .get(Uri.parse('${widget.server.endpoint.baseUrl}/healthz'))
          .timeout(const Duration(seconds: 4));
      if (health.statusCode < 200 || health.statusCode > 299) {
        throw Exception('healthz ${health.statusCode}');
      }

      final monitor = await _client
          .get(
            Uri.parse(
              '${widget.server.endpoint.baseUrl}/v1/mobile/monitor/state',
            ),
          )
          .timeout(const Duration(seconds: 4));
      if (monitor.statusCode < 200 || monitor.statusCode > 299) {
        throw Exception('monitor ${monitor.statusCode}');
      }

      final payload = jsonDecode(monitor.body) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _applySnapshot(MonitorSnapshot.fromJson(payload));
          _connected = true;
          _statusText = 'connected';
          _errorText = '';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _connected = false;
          _statusText = 'offline';
          _errorText = error.toString();
        });
      }
    } finally {
      _requestInFlight = false;
      if (manual && mounted) {
        setState(() {
          _manualLoading = false;
        });
      }
    }
  }

  void _applySnapshot(MonitorSnapshot snapshot) {
    _snapshot = snapshot.copyWithLatency(_snapshot.latencyMs);
    if (snapshot.batchActive) {
      if (snapshot.batchItemCode.isNotEmpty) {
        _selectedItem = MobileItem(
          itemCode: snapshot.batchItemCode,
          itemName: snapshot.batchItemName.isEmpty
              ? snapshot.batchItemCode
              : snapshot.batchItemName,
        );
      }
      if (snapshot.batchWarehouse.isNotEmpty) {
        _selectedWarehouse = MobileWarehouse(
          warehouse: snapshot.batchWarehouse,
        );
      }
    }
  }

  Uri _apiUri(String path, [Map<String, String?> query = const {}]) {
    final filtered = <String, String>{};
    for (final entry in query.entries) {
      final value = entry.value?.trim() ?? '';
      if (value.isNotEmpty) {
        filtered[entry.key] = value;
      }
    }
    return Uri.parse(
      '${widget.server.endpoint.baseUrl}$path',
    ).replace(queryParameters: filtered.isEmpty ? null : filtered);
  }

  void _scheduleItemSearch() {
    _itemSearchDebounce?.cancel();
    _itemSearchDebounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(_loadItems(query: _itemSearchController.text));
    });
  }

  void _scheduleWarehouseSearch() {
    if (_selectedItem == null) {
      return;
    }
    _warehouseSearchDebounce?.cancel();
    _warehouseSearchDebounce = Timer(const Duration(milliseconds: 220), () {
      unawaited(
        _loadWarehouses(
          itemCode: _selectedItem!.itemCode,
          query: _warehouseSearchController.text,
        ),
      );
    });
  }

  Future<void> _loadItems({String query = ''}) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _itemsLoading = true;
      _itemsError = '';
    });
    try {
      final response = await _client
          .get(_apiUri('/v1/mobile/items', {'query': query, 'limit': '12'}))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw Exception('items ${response.statusCode}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rawItems =
          (payload['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final items = rawItems.map(MobileItem.fromJson).toList(growable: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _itemsLoading = false;
        if (_selectedItem != null &&
            items.every((item) => item.itemCode != _selectedItem!.itemCode) &&
            !_snapshot.batchActive) {
          _selectedItem = null;
          _selectedWarehouse = null;
          _warehouses = const [];
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _itemsLoading = false;
        _itemsError = error.toString();
      });
    }
  }

  Future<void> _loadWarehouses({
    required String itemCode,
    String query = '',
  }) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _warehousesLoading = true;
      _warehousesError = '';
    });
    try {
      final response = await _client
          .get(
            _apiUri(
              '/v1/mobile/items/${Uri.encodeComponent(itemCode)}/warehouses',
              {'query': query, 'limit': '12'},
            ),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw Exception('warehouses ${response.statusCode}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rawWarehouses =
          (payload['warehouses'] as List?)?.cast<Map<String, dynamic>>() ??
          const [];
      final warehouses = rawWarehouses
          .map(MobileWarehouse.fromJson)
          .toList(growable: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _warehouses = warehouses;
        _warehousesLoading = false;
        if (_selectedWarehouse != null &&
            warehouses.every(
              (warehouse) =>
                  warehouse.warehouse != _selectedWarehouse!.warehouse,
            ) &&
            !_snapshot.batchActive) {
          _selectedWarehouse = null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _warehousesLoading = false;
        _warehousesError = error.toString();
      });
    }
  }

  Future<void> _selectItem(MobileItem item) async {
    setState(() {
      _selectedItem = item;
      _selectedWarehouse = null;
      _warehouses = const [];
      _warehouseSearchController.clear();
    });
    await _loadWarehouses(itemCode: item.itemCode);
  }

  Future<void> _startBatch() async {
    final item = _selectedItem;
    final warehouse = _selectedWarehouse;
    if (item == null || warehouse == null || _batchActionLoading) {
      return;
    }
    setState(() {
      _batchActionLoading = true;
      _warehousesError = '';
    });
    try {
      final response = await _client
          .post(
            _apiUri('/v1/mobile/batch/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'item_code': item.itemCode,
              'item_name': item.itemName,
              'warehouse': warehouse.warehouse,
            }),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw Exception('batch start ${response.statusCode}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final batch =
          (payload['batch'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = _snapshot.copyWithBatch(MobileBatchState.fromJson(batch));
        _batchActionLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _batchActionLoading = false;
        _warehousesError = error.toString();
      });
    }
  }

  Future<void> _stopBatch() async {
    if (_batchActionLoading) {
      return;
    }
    setState(() {
      _batchActionLoading = true;
      _warehousesError = '';
    });
    try {
      final response = await _client
          .post(_apiUri('/v1/mobile/batch/stop'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw Exception('batch stop ${response.statusCode}');
      }
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final batch =
          (payload['batch'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = _snapshot.copyWithBatch(MobileBatchState.fromJson(batch));
        _batchActionLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _batchActionLoading = false;
        _warehousesError = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final server = widget.server;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onChangeServer,
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Change server',
        ),
        title: Text(server.handshake.serverName),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _selectedSection == 0
            ? _DashboardScrollView(
                key: const ValueKey('control-section'),
                child: _buildControlSection(context, theme, scheme, server),
              )
            : _selectedSection == 1
            ? _DashboardScrollView(
                key: const ValueKey('line-section'),
                child: _buildLineSection(context, theme, scheme, server),
              )
            : _DashboardScrollView(
                key: const ValueKey('server-section'),
                child: _buildServerSection(context, theme, scheme, server),
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedSection,
        onDestinationSelected: (index) {
          setState(() {
            _selectedSection = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Control',
          ),
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Line',
          ),
          NavigationDestination(
            icon: Icon(Icons.health_and_safety_outlined),
            selectedIcon: Icon(Icons.health_and_safety),
            label: 'Server',
          ),
        ],
      ),
    );
  }

  Widget _buildServerSection(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    DiscoveredServer server,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.handshake.displayName,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    server.endpoint.baseUrl,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Chip(
              avatar: Icon(
                _connected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 18,
              ),
              label: Text(_connected ? 'Connected' : 'Offline'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(server.handshake.role.toUpperCase())),
            Chip(label: Text(server.handshake.serverRef)),
            if (server.latencyMs > 0)
              Chip(label: Text('${server.latencyMs} ms')),
          ],
        ),
        const SizedBox(height: 22),
        _SectionLabel(title: 'Server health', subtitle: ''),
        if (_errorText.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _errorText,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: 14),
        _MiniIconRow(
          icon: Icons.wifi_tethering,
          text: _connected ? _snapshot.serverLabel : server.endpoint.baseUrl,
        ),
        const SizedBox(height: 14),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        const SizedBox(height: 14),
        _MiniIconRow(
          icon: Icons.monitor_heart_outlined,
          text: _connected
              ? 'Live snapshot qabul qilinyapti'
              : 'Live stream ulanmagan',
        ),
        const SizedBox(height: 14),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        const SizedBox(height: 14),
        _MiniIconRow(
          icon: Icons.badge_outlined,
          text:
              '${server.handshake.displayName} • ${server.handshake.role.toUpperCase()}',
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _manualLoading ? null : () => _refresh(manual: true),
                child: const Icon(Icons.refresh_rounded),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: widget.onChangeServer,
                child: const Icon(Icons.dns_rounded),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLineSection(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    DiscoveredServer server,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Line overview',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _connected
                        ? 'Tanlangan serverdan live line holati olindi.'
                        : 'Line holati hozir offline.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Chip(
              avatar: Icon(
                _connected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 18,
              ),
              label: Text(_connected ? 'LIVE' : 'OFFLINE'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _StatusGrid(snapshot: _snapshot),
        const SizedBox(height: 26),
        _SectionLabel(title: 'Line details', subtitle: ''),
        const SizedBox(height: 12),
        _MiniIconRow(
          icon: Icons.scale_outlined,
          text: _connected
              ? _snapshot.monitorLabel
              : 'Scale, Zebra, batch va print request holati',
        ),
        const SizedBox(height: 16),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        const SizedBox(height: 16),
        _MiniIconRow(
          icon: Icons.print_outlined,
          text: _connected
              ? _snapshot.printerLabel
              : 'Printer trace va action holati',
        ),
        const SizedBox(height: 16),
        Divider(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        const SizedBox(height: 16),
        _MiniIconRow(icon: Icons.link_outlined, text: server.endpoint.baseUrl),
      ],
    );
  }

  Widget _buildControlSection(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    DiscoveredServer server,
  ) {
    final selectedProduct = _selectedItem;
    final selectedWarehouse = _selectedWarehouse;
    final batchRunning = _snapshot.batchActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Control panel',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Chip(
              avatar: Icon(
                batchRunning
                    ? Icons.play_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                size: 18,
              ),
              label: Text(batchRunning ? 'BATCH ON' : 'BATCH OFF'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _MetricSummary(
                title: 'Live kg',
                value: _snapshot.scaleValue,
                caption: _snapshot.scaleCaption,
                icon: Icons.scale_outlined,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: _MetricSummary(
                title: 'Selected product',
                value: selectedProduct?.itemCode ?? 'None',
                caption: selectedProduct?.itemName ?? 'Product tanlanmagan',
                icon: Icons.inventory_2_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _MiniIconRow(
          icon: Icons.speed_outlined,
          text: _snapshot.latencyMs > 0 ? '${_snapshot.latencyMs} ms' : '—',
        ),
        if (_snapshot.batchActive) ...[
          const SizedBox(height: 12),
          _MiniIconRow(
            icon: Icons.playlist_add_check_circle_outlined,
            text:
                '${_snapshot.batchItemName.isEmpty ? _snapshot.batchItemCode : _snapshot.batchItemName} • ${_snapshot.batchWarehouse}',
          ),
        ],
        const SizedBox(height: 28),
        _SectionLabel(title: 'Item selection', subtitle: ''),
        const SizedBox(height: 8),
        TextField(
          controller: _itemSearchController,
          decoration: const InputDecoration(
            labelText: 'Item qidirish',
            hintText: 'Masalan: tea, cotton, bag',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 10),
        if (_itemsLoading)
          const LinearProgressIndicator(minHeight: 2)
        else if (_itemsError.isNotEmpty)
          Text(
            _itemsError,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else if (_items.isEmpty)
          Text(
            'Item topilmadi.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Column(
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                _ItemOptionTile(
                  item: _items[i],
                  selected: selectedProduct?.itemCode == _items[i].itemCode,
                  onTap: batchRunning ? null : () => _selectItem(_items[i]),
                ),
                if (i != _items.length - 1)
                  Divider(
                    height: 1,
                    indent: 52,
                    endIndent: 0,
                    color: scheme.outlineVariant.withValues(alpha: 0.8),
                  ),
              ],
            ],
          ),
        const SizedBox(height: 28),
        _SectionLabel(title: 'Warehouse selection', subtitle: ''),
        const SizedBox(height: 8),
        TextField(
          controller: _warehouseSearchController,
          enabled: selectedProduct != null && !batchRunning,
          decoration: const InputDecoration(
            labelText: 'Warehouse qidirish',
            hintText: 'Masalan: stores, raw, main',
            prefixIcon: Icon(Icons.warehouse_outlined),
          ),
        ),
        const SizedBox(height: 10),
        if (_warehousesLoading)
          const LinearProgressIndicator(minHeight: 2)
        else if (_warehousesError.isNotEmpty)
          Text(
            _warehousesError,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else if (selectedProduct == null)
          Text(
            'Item tanlang, keyin warehouse chiqadi.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else if (_warehouses.isEmpty)
          Text(
            'Warehouse topilmadi.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Column(
            children: [
              for (var i = 0; i < _warehouses.length; i++) ...[
                _WarehouseOptionTile(
                  warehouse: _warehouses[i],
                  selected:
                      selectedWarehouse?.warehouse == _warehouses[i].warehouse,
                  onTap: batchRunning
                      ? null
                      : () {
                          setState(() {
                            _selectedWarehouse = _warehouses[i];
                          });
                        },
                ),
                if (i != _warehouses.length - 1)
                  Divider(
                    height: 1,
                    indent: 52,
                    endIndent: 0,
                    color: scheme.outlineVariant.withValues(alpha: 0.8),
                  ),
              ],
            ],
          ),
        const SizedBox(height: 28),
        _SectionLabel(title: 'Batch actions', subtitle: ''),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    selectedProduct == null ||
                        selectedWarehouse == null ||
                        batchRunning ||
                        _batchActionLoading
                    ? null
                    : _startBatch,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _batchActionLoading ? 'Starting...' : 'Batch Start',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: batchRunning && !_batchActionLoading
                    ? _stopBatch
                    : null,
                icon: const Icon(Icons.stop_rounded),
                label: Text(_batchActionLoading ? 'Stopping...' : 'Batch Stop'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DashboardScrollView extends StatelessWidget {
  const _DashboardScrollView({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [child],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        if (subtitle.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricSummary extends StatelessWidget {
  const _MetricSummary({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: scheme.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                caption,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniIconRow extends StatelessWidget {
  const _MiniIconRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: scheme.primary, size: 20),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _ServerHeaderCard extends StatelessWidget {
  const _ServerHeaderCard({
    required this.connected,
    required this.statusText,
    required this.displayName,
    required this.endpoint,
    required this.role,
    required this.serverRef,
    required this.latencyMs,
  });

  final bool connected;
  final String statusText;
  final String displayName;
  final String endpoint;
  final String role;
  final String serverRef;
  final int latencyMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: connected
                      ? scheme.secondaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  connected ? 'Connected' : 'Selected server',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: connected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            endpoint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(role.toUpperCase())),
              Chip(label: Text(serverRef)),
              if (latencyMs > 0) Chip(label: Text('$latencyMs ms')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveMetricCard extends StatelessWidget {
  const _LiveMetricCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary, size: 20),
          const SizedBox(height: 18),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemOptionTile extends StatelessWidget {
  const _ItemOptionTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final MobileItem item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? scheme.secondaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
        leading: Icon(
          Icons.inventory_2_outlined,
          color: selected ? scheme.onSecondaryContainer : scheme.primary,
        ),
        title: Text(
          item.itemCode,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
          ),
        ),
        subtitle: Text(
          item.itemName,
          style: theme.textTheme.bodySmall?.copyWith(
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        trailing: selected
            ? Icon(
                Icons.check_circle_rounded,
                color: scheme.onSecondaryContainer,
              )
            : Icon(Icons.circle_outlined, color: scheme.outline),
      ),
    );
  }
}

class _WarehouseOptionTile extends StatelessWidget {
  const _WarehouseOptionTile({
    required this.warehouse,
    required this.selected,
    required this.onTap,
  });

  final MobileWarehouse warehouse;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? scheme.secondaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
        leading: Icon(
          Icons.warehouse_outlined,
          color: selected ? scheme.onSecondaryContainer : scheme.primary,
        ),
        title: Text(
          warehouse.warehouse,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
          ),
        ),
        subtitle: Text(
          warehouse.caption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        trailing: selected
            ? Icon(
                Icons.check_circle_rounded,
                color: scheme.onSecondaryContainer,
              )
            : Icon(Icons.circle_outlined, color: scheme.outline),
      ),
    );
  }
}

class _ScanningState extends StatelessWidget {
  const _ScanningState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          const SizedBox(width: 14),
          Text(
            'Scanning...',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyServerState extends StatelessWidget {
  const _EmptyServerState({required this.onManualAdd});

  final VoidCallback onManualAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No servers',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pull down to refresh or add address.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onManualAdd, child: const Text('Add address')),
        ],
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server, required this.onOpen});

  final DiscoveredServer server;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListTile(
      onTap: onOpen,
      dense: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      leading: Icon(
        _wifiIconForLatency(server.latencyMs),
        color: scheme.primary,
        size: 28,
      ),
      title: Text(
        server.handshake.serverName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        server.endpoint.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        'Connect',
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ServerList extends StatelessWidget {
  const _ServerList({required this.servers, required this.onOpenServer});

  final List<DiscoveredServer> servers;
  final ValueChanged<DiscoveredServer> onOpenServer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        for (var i = 0; i < servers.length; i++) ...[
          _ServerCard(
            server: servers[i],
            onOpen: () => onOpenServer(servers[i]),
          ),
          if (i != servers.length - 1)
            Divider(
              height: 1,
              indent: 52,
              endIndent: 6,
              color: scheme.outlineVariant,
            ),
        ],
      ],
    );
  }
}

IconData _wifiIconForLatency(int latencyMs) {
  if (latencyMs <= 8) {
    return Icons.signal_wifi_4_bar_rounded;
  }
  if (latencyMs <= 25) {
    return Icons.network_wifi_3_bar_rounded;
  }
  if (latencyMs <= 60) {
    return Icons.network_wifi_2_bar_rounded;
  }
  return Icons.network_wifi_1_bar_rounded;
}

class ManualServerSheet extends StatefulWidget {
  const ManualServerSheet({required this.client, super.key});

  final http.Client client;

  @override
  State<ManualServerSheet> createState() => _ManualServerSheetState();
}

class _ManualServerSheetState extends State<ManualServerSheet> {
  late final TextEditingController _controller;
  bool _checking = false;
  String _errorText = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _sanitizeManualServerAddress(_configuredApiBaseUrl),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) {
      return;
    }

    setState(() {
      _checking = true;
      _errorText = '';
    });

    final endpoint = parseServerEndpoint(_controller.text);
    if (endpoint == null) {
      setState(() {
        _checking = false;
        _errorText = 'Address format is invalid';
      });
      return;
    }
    if (_shouldSkipDiscoveryHost(endpoint.host)) {
      setState(() {
        _checking = false;
        _errorText = 'Use Wi-Fi server address, not localhost';
      });
      return;
    }

    final server = await probeServer(
      widget.client,
      endpoint,
      timeout: _manualProbeTimeout,
    );
    if (!mounted) {
      return;
    }

    if (server == null) {
      setState(() {
        _checking = false;
        _errorText = 'Handshake failed for this server';
      });
      return;
    }

    Navigator.of(context).pop(server);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottomInset + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add server',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Example: 192.168.1.12:8081',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'http://192.168.1.12:8081',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_errorText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_errorText, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _checking ? null : _submit,
            icon: const Icon(Icons.link_rounded),
            label: Text(_checking ? 'Checking...' : 'Connect to server'),
          ),
        ],
      ),
    );
  }
}

class _StatusGrid extends StatelessWidget {
  const _StatusGrid({required this.snapshot});

  final MonitorSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StatusRow(
          title: 'Scale',
          value: snapshot.scaleValue,
          caption: snapshot.scaleCaption,
          icon: Icons.scale_outlined,
        ),
        Divider(color: Theme.of(context).colorScheme.outlineVariant),
        _StatusRow(
          title: 'Zebra',
          value: snapshot.zebraValue,
          caption: snapshot.zebraCaption,
          icon: Icons.print_outlined,
        ),
        Divider(color: Theme.of(context).colorScheme.outlineVariant),
        _StatusRow(
          title: 'Batch',
          value: snapshot.batchValue,
          caption: snapshot.batchCaption,
          icon: Icons.inventory_2_outlined,
        ),
        Divider(color: Theme.of(context).colorScheme.outlineVariant),
        _StatusRow(
          title: 'Bridge',
          value: snapshot.bridgeValue,
          caption: snapshot.bridgeCaption,
          icon: Icons.sync_outlined,
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.primary, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: scheme.onSecondaryContainer),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class MonitorSnapshot {
  const MonitorSnapshot({
    required this.scaleValue,
    required this.scaleCaption,
    required this.zebraValue,
    required this.zebraCaption,
    required this.batchValue,
    required this.batchCaption,
    required this.bridgeValue,
    required this.bridgeCaption,
    required this.serverLabel,
    required this.monitorLabel,
    required this.printerLabel,
    required this.batchActive,
    required this.batchItemCode,
    required this.batchItemName,
    required this.batchWarehouse,
    required this.latencyMs,
  });

  factory MonitorSnapshot.empty() {
    return const MonitorSnapshot(
      scaleValue: '--',
      scaleCaption: 'Live qty',
      zebraValue: 'Idle',
      zebraCaption: 'Printer state',
      batchValue: 'Stopped',
      batchCaption: 'Workflow',
      bridgeValue: 'Ready',
      bridgeCaption: 'Shared state',
      serverLabel: 'API: idle',
      monitorLabel: 'Scale, Zebra, batch va print request holati',
      printerLabel: 'Printer trace va action holati',
      batchActive: false,
      batchItemCode: '',
      batchItemName: '',
      batchWarehouse: '',
      latencyMs: 0,
    );
  }

  factory MonitorSnapshot.fromJson(Map<String, dynamic> json) {
    final state = (json['state'] as Map?)?.cast<String, dynamic>() ?? const {};
    final scale = (state['scale'] as Map?)?.cast<String, dynamic>() ?? const {};
    final zebra = (state['zebra'] as Map?)?.cast<String, dynamic>() ?? const {};
    final batch = (state['batch'] as Map?)?.cast<String, dynamic>() ?? const {};
    final printRequest =
        (state['print_request'] as Map?)?.cast<String, dynamic>() ?? const {};
    final printer =
        (json['printer'] as Map?)?.cast<String, dynamic>() ?? const {};

    final scaleWeight = scale['weight'];
    final scaleUnit = _text(scale['unit'], fallback: 'kg');
    final scaleStable = scale['stable'] == true ? 'stable' : 'live';

    final zebraVerify = _text(zebra['verify'], fallback: 'idle');
    final zebraAction = _text(zebra['action'], fallback: 'printer state');

    final batchActive = batch['active'] == true;
    final batchItemCode = _text(batch['item_code']);
    final batchItem = _text(batch['item_name'], fallback: batchItemCode);
    final batchWarehouse = _text(batch['warehouse']);

    final printStatus = _text(printRequest['status'], fallback: 'idle');
    final printerMode = _text(
      printer['print_mode'],
      fallback: 'trace unavailable',
    );

    return MonitorSnapshot(
      scaleValue: scaleWeight == null ? '--' : '$scaleWeight $scaleUnit',
      scaleCaption: scaleStable,
      zebraValue: zebraVerify.toUpperCase(),
      zebraCaption: zebraAction,
      batchValue: batchActive ? 'Active' : 'Stopped',
      batchCaption: batchItem.isEmpty ? 'Workflow' : batchItem,
      bridgeValue: printStatus == 'idle' ? 'Ready' : printStatus,
      bridgeCaption: _text(printRequest['epc'], fallback: 'Shared state'),
      serverLabel: _text(json['ok'], fallback: 'unknown') == 'true'
          ? 'API: online'
          : 'API: offline',
      monitorLabel: batchItem.isEmpty ? 'No active batch' : 'Batch: $batchItem',
      printerLabel: 'Print mode: $printerMode',
      batchActive: batchActive,
      batchItemCode: batchItemCode,
      batchItemName: batchItem,
      batchWarehouse: batchWarehouse,
      latencyMs: 0,
    );
  }

  MonitorSnapshot copyWithBatch(MobileBatchState batch) {
    final itemName = batch.displayItemName;
    return MonitorSnapshot(
      scaleValue: scaleValue,
      scaleCaption: scaleCaption,
      zebraValue: zebraValue,
      zebraCaption: zebraCaption,
      batchValue: batch.active ? 'Active' : 'Stopped',
      batchCaption: itemName.isEmpty ? 'Workflow' : itemName,
      bridgeValue: bridgeValue,
      bridgeCaption: bridgeCaption,
      serverLabel: serverLabel,
      monitorLabel: itemName.isEmpty ? 'No active batch' : 'Batch: $itemName',
      printerLabel: printerLabel,
      batchActive: batch.active,
      batchItemCode: batch.itemCode,
      batchItemName: itemName,
      batchWarehouse: batch.warehouse,
      latencyMs: latencyMs,
    );
  }

  final String scaleValue;
  final String scaleCaption;
  final String zebraValue;
  final String zebraCaption;
  final String batchValue;
  final String batchCaption;
  final String bridgeValue;
  final String bridgeCaption;
  final String serverLabel;
  final String monitorLabel;
  final String printerLabel;
  final bool batchActive;
  final String batchItemCode;
  final String batchItemName;
  final String batchWarehouse;
  final int latencyMs;

  MonitorSnapshot copyWithLatency(int latencyMs) {
    return MonitorSnapshot(
      scaleValue: scaleValue,
      scaleCaption: scaleCaption,
      zebraValue: zebraValue,
      zebraCaption: zebraCaption,
      batchValue: batchValue,
      batchCaption: batchCaption,
      bridgeValue: bridgeValue,
      bridgeCaption: bridgeCaption,
      serverLabel: serverLabel,
      monitorLabel: monitorLabel,
      printerLabel: printerLabel,
      batchActive: batchActive,
      batchItemCode: batchItemCode,
      batchItemName: batchItemName,
      batchWarehouse: batchWarehouse,
      latencyMs: latencyMs,
    );
  }
}

class MobileItem {
  const MobileItem({required this.itemCode, required this.itemName});

  factory MobileItem.fromJson(Map<String, dynamic> json) {
    final itemCode = _text(json['item_code'], fallback: _text(json['name']));
    final itemName = _text(json['item_name'], fallback: itemCode);
    return MobileItem(itemCode: itemCode, itemName: itemName);
  }

  final String itemCode;
  final String itemName;
}

class MobileWarehouse {
  const MobileWarehouse({required this.warehouse, this.actualQty});

  factory MobileWarehouse.fromJson(Map<String, dynamic> json) {
    return MobileWarehouse(
      warehouse: _text(json['warehouse']),
      actualQty: (json['actual_qty'] as num?)?.toDouble(),
    );
  }

  final String warehouse;
  final double? actualQty;

  String get caption => actualQty == null
      ? 'Qoldiq mavjud'
      : 'Qoldiq: ${actualQty!.toStringAsFixed(3)}';

  String get label => actualQty == null
      ? warehouse
      : '$warehouse • ${actualQty!.toStringAsFixed(3)}';
}

class MobileBatchState {
  const MobileBatchState({
    required this.active,
    required this.itemCode,
    required this.itemName,
    required this.warehouse,
  });

  factory MobileBatchState.fromJson(Map<String, dynamic> json) {
    return MobileBatchState(
      active: json['active'] == true,
      itemCode: _text(json['item_code']),
      itemName: _text(json['item_name']),
      warehouse: _text(json['warehouse']),
    );
  }

  final bool active;
  final String itemCode;
  final String itemName;
  final String warehouse;

  String get displayItemName => itemName.isEmpty ? itemCode : itemName;
}

class DiscoveryResult {
  const DiscoveryResult({required this.servers, required this.candidateCount});

  final List<DiscoveredServer> servers;
  final int candidateCount;
}

class DiscoveredServer {
  const DiscoveredServer({
    required this.endpoint,
    required this.handshake,
    required this.latencyMs,
  });

  final ServerEndpoint endpoint;
  final ServerHandshake handshake;
  final int latencyMs;

  String get discoveryKey {
    final ref = handshake.serverRef.trim().toLowerCase();
    final name = handshake.serverName.trim().toLowerCase();
    if (ref.isNotEmpty && ref != 'unknown' && ref != 'legacy-healthz') {
      return '$ref|$name';
    }
    return endpoint.label.toLowerCase();
  }
}

class ServerEndpoint {
  const ServerEndpoint({
    required this.host,
    required this.port,
    required this.baseUrl,
  });

  final String host;
  final int port;
  final String baseUrl;

  String get label => '$host:$port';
}

class ServerHandshake {
  const ServerHandshake({
    required this.serverName,
    required this.displayName,
    required this.role,
    required this.serverRef,
  });

  factory ServerHandshake.fromJson(Map<String, dynamic> json) {
    return ServerHandshake(
      serverName: _text(json['server_name'], fallback: 'gscale-zebra'),
      displayName: _text(json['display_name'], fallback: 'Operator'),
      role: _text(json['role'], fallback: 'operator'),
      serverRef: _text(json['server_ref'], fallback: 'unknown'),
    );
  }

  final String serverName;
  final String displayName;
  final String role;
  final String serverRef;
}

Future<DiscoveryResult> discoverServers(
  http.Client client, {
  ServerEndpoint? preferredEndpoint,
}) async {
  final announcementsFuture = _loadDiscoveryAnnouncements();
  final candidates = await _loadCandidateHosts();
  final resultsByKey = <String, DiscoveredServer>{};
  final probeTargets = <ServerEndpoint>[];
  final seenBaseUrls = <String>{};

  void addTarget(ServerEndpoint endpoint) {
    if (seenBaseUrls.add(endpoint.baseUrl)) {
      probeTargets.add(endpoint);
    }
  }

  if (preferredEndpoint != null &&
      !_shouldSkipDiscoveryHost(preferredEndpoint.host)) {
    addTarget(preferredEndpoint);
  }
  for (final host in candidates) {
    if (_shouldSkipDiscoveryHost(host)) {
      continue;
    }
    addTarget(
      ServerEndpoint(
        host: host,
        port: _defaultApiPort,
        baseUrl: 'http://$host:$_defaultApiPort',
      ),
    );
  }

  var candidateCount = probeTargets.length;
  final directScanned = await _probeServers(
    client,
    probeTargets,
    timeout: _fastProbeTimeout,
  );
  _mergeDiscoveredServers(resultsByKey, directScanned);

  final announcements = await announcementsFuture;
  for (final announcement in announcements) {
    final server = DiscoveredServer(
      endpoint: ServerEndpoint(
        host: announcement.host,
        port: announcement.httpPort,
        baseUrl: 'http://${announcement.host}:${announcement.httpPort}',
      ),
      handshake: ServerHandshake(
        serverName: announcement.serverName,
        displayName: announcement.displayName,
        role: announcement.role,
        serverRef: announcement.serverRef,
      ),
      latencyMs: announcement.latencyMs,
    );
    _mergeDiscoveredServer(resultsByKey, server);
  }

  if (resultsByKey.isEmpty) {
    final subnetHosts = await _loadSubnetCandidateHosts();
    final fallbackTargets = <ServerEndpoint>[];
    for (final host in subnetHosts) {
      final endpoint = ServerEndpoint(
        host: host,
        port: _defaultApiPort,
        baseUrl: 'http://$host:$_defaultApiPort',
      );
      if (seenBaseUrls.add(endpoint.baseUrl)) {
        fallbackTargets.add(endpoint);
      }
    }
    candidateCount += fallbackTargets.length;
    final fallbackScanned = await _probeServers(
      client,
      fallbackTargets,
      timeout: _fallbackProbeTimeout,
      concurrency: _fallbackProbeConcurrency,
    );
    _mergeDiscoveredServers(resultsByKey, fallbackScanned);
  }

  final results = resultsByKey.values.toList();

  results.sort((left, right) {
    if (preferredEndpoint != null) {
      final leftPreferred = left.endpoint.baseUrl == preferredEndpoint.baseUrl;
      final rightPreferred =
          right.endpoint.baseUrl == preferredEndpoint.baseUrl;
      if (leftPreferred != rightPreferred) {
        return leftPreferred ? -1 : 1;
      }
    }
    final latencyCmp = left.latencyMs.compareTo(right.latencyMs);
    if (latencyCmp != 0) {
      return latencyCmp;
    }
    return left.endpoint.baseUrl.compareTo(right.endpoint.baseUrl);
  });

  return DiscoveryResult(servers: results, candidateCount: candidateCount);
}

Future<List<String>> _loadCandidateHosts() async {
  try {
    return await network_candidates.collectCandidateHosts();
  } catch (_) {
    return const ['gscale.local'];
  }
}

Future<List<String>> _loadSubnetCandidateHosts() async {
  try {
    return await network_candidates.collectSubnetCandidateHosts();
  } catch (_) {
    return const [];
  }
}

Future<List<network_candidates.DiscoveryAnnouncement>>
_loadDiscoveryAnnouncements() async {
  try {
    return await network_candidates.discoverAnnouncements(
      port: _discoveryPort,
      timeout: _udpDiscoveryTimeout,
    );
  } catch (_) {
    return const <network_candidates.DiscoveryAnnouncement>[];
  }
}

void _mergeDiscoveredServers(
  Map<String, DiscoveredServer> resultsByKey,
  Iterable<DiscoveredServer> servers,
) {
  for (final server in servers) {
    _mergeDiscoveredServer(resultsByKey, server);
  }
}

void _mergeDiscoveredServer(
  Map<String, DiscoveredServer> resultsByKey,
  DiscoveredServer server,
) {
  final existing = resultsByKey[server.discoveryKey];
  if (existing == null || server.latencyMs < existing.latencyMs) {
    resultsByKey[server.discoveryKey] = server;
  }
}

Future<List<DiscoveredServer>> _probeServers(
  http.Client client,
  List<ServerEndpoint> endpoints, {
  Duration timeout = _fastProbeTimeout,
  int concurrency = 12,
}) async {
  if (endpoints.isEmpty) {
    return const [];
  }

  final results = <DiscoveredServer>[];
  var nextIndex = 0;
  final workerCount = endpoints.length < concurrency
      ? endpoints.length
      : concurrency;

  Future<void> worker() async {
    while (nextIndex < endpoints.length) {
      final endpoint = endpoints[nextIndex++];
      final server = await probeServer(client, endpoint, timeout: timeout);
      if (server != null) {
        results.add(server);
      }
    }
  }

  await Future.wait(List.generate(workerCount, (_) => worker()));
  return results;
}

Future<DiscoveredServer?> probeServer(
  http.Client client,
  ServerEndpoint endpoint, {
  Duration timeout = _fastProbeTimeout,
}) async {
  final stopwatch = Stopwatch()..start();

  try {
    final handshakeResponse = await client
        .get(Uri.parse('${endpoint.baseUrl}/v1/mobile/handshake'))
        .timeout(timeout);
    if (handshakeResponse.statusCode >= 200 &&
        handshakeResponse.statusCode < 300) {
      final json = jsonDecode(handshakeResponse.body) as Map<String, dynamic>;
      if (_text(json['service']) != 'mobileapi') {
        return null;
      }
      stopwatch.stop();
      return DiscoveredServer(
        endpoint: endpoint,
        handshake: ServerHandshake.fromJson(json),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }

    final healthResponse = await client
        .get(Uri.parse('${endpoint.baseUrl}/healthz'))
        .timeout(timeout);
    if (healthResponse.statusCode < 200 || healthResponse.statusCode > 299) {
      return null;
    }

    final health = jsonDecode(healthResponse.body) as Map<String, dynamic>;
    if (_text(health['service']) != 'mobileapi') {
      return null;
    }

    stopwatch.stop();
    return DiscoveredServer(
      endpoint: endpoint,
      handshake: ServerHandshake(
        serverName: endpoint.host,
        displayName: 'Operator',
        role: 'operator',
        serverRef: 'legacy-healthz',
      ),
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  } catch (_) {
    return null;
  }
}

ServerEndpoint? parseServerEndpoint(String raw) {
  var value = raw.trim();
  if (value.isEmpty) {
    return null;
  }
  if (!value.contains('://')) {
    value = 'http://$value';
  }

  final uri = Uri.tryParse(value);
  if (uri == null || (uri.host.isEmpty && uri.path.isEmpty)) {
    return null;
  }

  final host = uri.host.isNotEmpty ? uri.host : uri.path;
  if (host.trim().isEmpty) {
    return null;
  }

  final port = uri.hasPort ? uri.port : _defaultApiPort;
  final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
  return ServerEndpoint(
    host: host,
    port: port,
    baseUrl: '$scheme://$host:$port',
  );
}

String _text(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) {
    return fallback;
  }
  return text;
}

Future<void> saveLastUsedServer(ServerEndpoint endpoint) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_lastServerKey, endpoint.baseUrl);
}

Future<ServerEndpoint?> loadLastUsedServer() async {
  final prefs = await SharedPreferences.getInstance();
  final value = prefs.getString(_lastServerKey);
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  final endpoint = parseServerEndpoint(value);
  if (endpoint == null || _shouldSkipDiscoveryHost(endpoint.host)) {
    await prefs.remove(_lastServerKey);
    return null;
  }
  return endpoint;
}

bool _shouldSkipDiscoveryHost(String host) {
  final normalized = host.trim().toLowerCase();
  return normalized == '127.0.0.1' ||
      normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '[::1]' ||
      normalized == '10.0.2.2';
}

String _sanitizeManualServerAddress(String raw) {
  final endpoint = parseServerEndpoint(raw);
  if (endpoint == null || _shouldSkipDiscoveryHost(endpoint.host)) {
    return _defaultWifiServerAddress;
  }
  return endpoint.baseUrl;
}
