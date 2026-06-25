import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';

/// Envuelve la pantalla principal y, la PRIMERA vez que CADA usuario usa la app,
/// muestra un tutorial rápido (con botón "Saltar"). El flag se guarda POR
/// usuario (clave con su id), así toda cuenta nueva lo ve una vez.
class TutorialGate extends StatefulWidget {
  final Widget child;
  const TutorialGate({super.key, required this.child});

  @override
  State<TutorialGate> createState() => _TutorialGateState();
}

class _TutorialGateState extends State<TutorialGate> {
  bool? _seen; // null mientras se carga

  // Clave por usuario: cada cuenta nueva ve el tutorial una vez.
  String get _prefKey {
    final uid = Supabase.instance.client.auth.currentUser?.id ?? 'anon';
    return 'seen_tutorial_v1_$uid';
  }

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _seen = prefs.getBool(_prefKey) ?? false);
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
    if (mounted) setState(() => _seen = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_seen == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_seen == true) return widget.child;
    return _TutorialScreen(onFinish: _finish);
  }
}

class _Slide {
  final IconData icon;
  final String titleKey;
  final String bodyKey;
  const _Slide(this.icon, this.titleKey, this.bodyKey);
}

class _TutorialScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const _TutorialScreen({required this.onFinish});

  @override
  State<_TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<_TutorialScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _slides = <_Slide>[
    _Slide(Icons.local_taxi, 'tut_1_title', 'tut_1_body'),
    _Slide(Icons.mic, 'tut_2_title', 'tut_2_body'),
    _Slide(Icons.insights, 'tut_3_title', 'tut_3_body'),
    _Slide(Icons.report_problem, 'tut_4_title', 'tut_4_body'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _slides.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      widget.onFinish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isLast = _page == _slides.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Botón "Saltar tutorial" siempre visible arriba a la derecha.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onFinish,
                child: Text(l.t('tut_skip')),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final s = _slides[i];
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(s.icon, size: 96, color: Colors.amber.shade700),
                        const SizedBox(height: 32),
                        Text(
                          l.t(s.titleKey),
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l.t(s.bodyKey),
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Indicadores de página.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page ? Colors.amber.shade700 : Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(isLast ? l.t('tut_start') : l.t('tut_next')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
