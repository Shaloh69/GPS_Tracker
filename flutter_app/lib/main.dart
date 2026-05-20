import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/tracker_service.dart';
import 'services/socket_service.dart';
import 'theme/app_theme.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final api     = ApiService();
  final auth    = AuthService(api);
  final tracker = TrackerService(api);
  final socket  = SocketService(tracker);

  await auth.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: tracker),
        ChangeNotifierProvider.value(value: socket),
      ],
      child: const GpsTrackerApp(),
    ),
  );
}

class GpsTrackerApp extends StatelessWidget {
  const GpsTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TraceX',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      home: Consumer<AuthService>(
        builder: (_, auth, __) {
          if (auth.isLoading) {
            return const Scaffold(
              backgroundColor: AppColors.surface,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.location_on_rounded,
                        size: 52, color: AppColors.blue500),
                    SizedBox(height: 16),
                    CircularProgressIndicator(color: AppColors.blue500),
                  ],
                ),
              ),
            );
          }
          return auth.isAuth ? const HomeScreen() : const LoginScreen();
        },
      ),
    );
  }
}
