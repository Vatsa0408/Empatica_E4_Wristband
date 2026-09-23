import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc/connection_bloc.dart';
import 'bloc/recording_bloc.dart';
import 'transport/ble_transport.dart';
import 'ui/home_page.dart';

class E4App extends StatelessWidget {
  const E4App({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<ConnectionBloc>(create: (_) => ConnectionBloc(BleTransport())),
        BlocProvider<RecordingBloc>(
          create: (context) => RecordingBloc(context.read<ConnectionBloc>().transport, context.read<ConnectionBloc>()),
        ),
      ],
      child: MaterialApp(
        title: 'E4 Integrator',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const HomePage(),
      ),
    );
  }
}
