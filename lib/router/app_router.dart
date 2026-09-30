import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import '../promptlib/git_service.dart';
import '../promptlib/prompt_store.dart';
import '../promptlib/ui/library_controller.dart';
import '../screens/home_screen.dart';
import '../screens/article_screen.dart';
import '../screens/debug_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/library_screen.dart';
import '../screens/prompt_detail_screen.dart';
import '../screens/onboarding_screen.dart';
import '../models/feed_item.dart';
import 'onboarding_state.dart';
import '../utils/app_toast.dart';

/// Navigator key used for programmatic navigation from outside the widget tree
/// (e.g. notification tap handlers).
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Application route configuration.
///
/// Routes:
/// - `/`        → [HomeScreen] (bottom nav with Feeds / Folders / Bookmarks / Settings / Skills)
/// - `/article` → [ArticleScreen] (expects a [FeedItem] via `state.extra`)
/// - `/debug`   → [DebugScreen] (hidden developer utilities)
/// - `/skills`  → [SkillsStandaloneRoute] (standalone skills catalog browser)
/// - `/library`     → [LibraryScreen] (prompt library browser over [LibraryController])
/// - `/library/:id` → [PromptDetailScreen] (single prompt + history entry point)
final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  observers: [appToastRouteObserver],
  initialLocation: '/',
  redirect: (context, state) {
    if (sessionOnboardingBypassed) return null;
    final seen =
        Hive.box('settings').get('hasSeenOnboarding', defaultValue: false)
            as bool;
    if (!seen && state.matchedLocation != '/onboarding') return '/onboarding';
    return null;
  },
  routes: [
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/article',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        final items = extra['items'] as List<FeedItem>;
        final initialIndex = extra['initialIndex'] as int;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ArticleScreen(items: items, initialIndex: initialIndex),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 350),
          reverseTransitionDuration: const Duration(milliseconds: 300),
        );
      },
    ),
    GoRoute(path: '/debug', builder: (context, state) => const DebugScreen()),
    GoRoute(
      path: '/skills',
      builder: (context, state) => const SkillsStandaloneRoute(),
    ),
    GoRoute(
      path: '/library',
      builder: (context, state) => const _LibraryRoute(),
    ),
    GoRoute(
      path: '/library/:id',
      builder: (context, state) {
        final String id = state.pathParameters['id'] ?? '';
        return _PromptDetailRoute(promptId: id);
      },
    ),
  ],
);

/// Deep-linkable `/skills` entry: standalone scaffold hosting the same
/// [SkillsScreen] shown as the 5th bottom-nav tab on `/`.
class SkillsStandaloneRoute extends StatelessWidget {
  const SkillsStandaloneRoute({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Skills')),
      body: const SkillsScreen(),
    );
  }
}

/// Builds an initialized [LibraryController] rooted at the app-documents
/// `promptlib` folder (`<docs>/promptlib`, holding `library/`,
/// `subscriptions/`, `.promptlib/`).
///
/// A fresh controller is built per navigation: cheap (file scan + YAML load)
/// and avoids sharing store/git lifecycle with the widget tree.
Future<_LibraryBackend> _initLibraryBackend() async {
  final dir = await getApplicationDocumentsDirectory();
  final String root = '${dir.path}/promptlib';
  final git = ProcessGitService(workingDirectory: root);
  final store = PromptStore(git: git);
  final controller = LibraryController(store: store, libraryRoot: root);
  await controller.init();
  return _LibraryBackend(controller: controller, git: git);
}

class _LibraryBackend {
  final LibraryController controller;
  final ProcessGitService git;
  const _LibraryBackend({required this.controller, required this.git});
}

/// Route entry for `/library`: initializes the backend, then shows
/// [LibraryScreen]. Shows a spinner while initializing and a plain error
/// when the folder cannot be prepared (never crashes).
class _LibraryRoute extends StatelessWidget {
  const _LibraryRoute();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LibraryBackend>(
      future: _initLibraryBackend(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('Library')),
            body: Center(
              child: Text('Library unavailable: ${snapshot.error}'),
            ),
          );
        }
        final backend = snapshot.data!;
        return LibraryScreen(
          controller: backend.controller,
          git: backend.git,
        );
      },
    );
  }
}

/// Route entry for `/library/:id`: initializes the backend, then shows
/// [PromptDetailScreen] for [promptId].
class _PromptDetailRoute extends StatelessWidget {
  final String promptId;
  const _PromptDetailRoute({required this.promptId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LibraryBackend>(
      future: _initLibraryBackend(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(title: const Text('Prompt')),
            body: Center(
              child: Text('Library unavailable: ${snapshot.error}'),
            ),
          );
        }
        final backend = snapshot.data!;
        return PromptDetailScreen(
          controller: backend.controller,
          promptId: promptId,
          git: backend.git,
        );
      },
    );
  }
}
