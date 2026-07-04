import 'package:flutter/material.dart';

import '../services/data_service.dart';

/// Franja de aviso de mantenimiento sobre toda la app. Consulta /app-config al
/// arrancar (y al volver a primer plano) y muestra el mensaje del admin si el
/// modo mantenimiento está activo. Best-effort: si falla, no muestra nada.
class MaintenanceBanner extends StatefulWidget {
  const MaintenanceBanner({super.key});

  @override
  State<MaintenanceBanner> createState() => _MaintenanceBannerState();
}

class _MaintenanceBannerState extends State<MaintenanceBanner>
    with WidgetsBindingObserver {
  String? _message; // null = sin mantenimiento

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final cfg = await DataService().appConfig();
      final on = cfg['maintenance'] == true;
      final msg = (cfg['maintenance_message'] as String?)?.trim();
      if (mounted) {
        setState(() => _message = on
            ? (msg?.isNotEmpty == true ? msg : 'Mantenimiento en curso.')
            : null);
      }
    } catch (_) {/* sin conexión: no molestamos */}
  }

  @override
  Widget build(BuildContext context) {
    if (_message == null) return const SizedBox.shrink();
    return Material(
      color: const Color(0xFF854F0B),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.build_circle, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_message!,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
