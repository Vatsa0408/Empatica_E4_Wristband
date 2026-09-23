import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/connection_bloc.dart';
import 'device_panel.dart';
import 'recording_panel.dart';
import 'signal_table.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('E4 Integrator')),
      body: BlocListener<ConnectionBloc, ConnectionState>(
        listenWhen: (previous, current) => current.status == ConnectionStatus.error && current.error != previous.error,
        listener: (context, state) {
          final error = state.error;
          if (error != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
          }
        },
        child: const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [DevicePanel(), SizedBox(height: 16), RecordingPanel(), SizedBox(height: 16), SignalTable()],
          ),
        ),
      ),
    );
  }
}
