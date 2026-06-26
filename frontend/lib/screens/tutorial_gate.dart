import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Tutorial de bienvenida (una sola vez por usuario). El "ya visto" se guarda en
/// la BD (users.tutorial_seen); el AuthGate decide cuándo mostrarlo y llama a
/// [onFinish] al terminar o saltar.
class _Slide {
  final IconData icon;
  final String titleKey;
  final String bodyKey;
  const _Slide(this.icon, this.titleKey, this.bodyKey);
}

class TutorialScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const TutorialScreen({super.key, required this.onFinish});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
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
