/// Calls a core route: the Backend isolate in the app, the core itself in tests.
typedef CoreCall = Future<Map<String, dynamic>> Function(String method, [Map<String, dynamic> params]);
