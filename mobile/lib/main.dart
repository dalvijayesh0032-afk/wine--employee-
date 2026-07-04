// WineFlow field app — OFFLINE-FIRST.
// Every action is written to a local queue (sqflite "outbox") immediately, then
// uploaded to the central server whenever the server is reachable. This is what
// makes the app work while the office server is off (e.g. 7 PM–9:30 AM): records
// are kept on the phone and flushed automatically when the server comes back.
//
// Correctness guarantees:
//  * each queued action carries a client_uuid  -> server de-duplicates (exactly-once)
//  * each queued action carries a client_ts    -> server keeps the ORIGINAL time,
//    not the upload time (so a 6 PM punch isn't recorded as 9:30 AM)
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';

const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:4000');
const _uuid = Uuid();

void main() => runApp(const WineFlowApp());

/* ----------------------------- API client ----------------------------- */
class Api {
  static String? token;
  static Future<void> loadToken() async =>
      token = (await SharedPreferences.getInstance()).getString('token');
  static Future<void> saveToken(String t) async {
    token = t;
    (await SharedPreferences.getInstance()).setString('token', t);
  }
  static Future<void> clear() async {
    token = null;
    (await SharedPreferences.getInstance()).remove('token');
  }
  static Map<String, String> get _h => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
  static Future<http.Response> post(String path, Map body) =>
      http.post(Uri.parse('$apiBase$path'), headers: _h, body: jsonEncode(body));
  static Future<http.Response> get(String path) =>
      http.get(Uri.parse('$apiBase$path'), headers: _h);
}

/* ----------------------------- Local outbox (sqflite) ----------------------------- */
class LocalDb {
  static Database? _db;
  static Future<Database> get _database async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'wineflow.db');
    _db = await openDatabase(path, version: 1, onCreate: (d, v) async {
      await d.execute('''CREATE TABLE outbox(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_uuid TEXT, endpoint TEXT, payload TEXT, label TEXT,
        created_at TEXT, status INTEGER DEFAULT 0, attempts INTEGER DEFAULT 0, last_error TEXT)''');
    });
    return _db!;
  }

  /// Save an action locally. status: 0=pending, 1=synced, 2=failed(parked)
  static Future<void> enqueue(String endpoint, Map payload, String label, {bool tsAsTs = false}) async {
    final d = await _database;
    final id = _uuid.v4();
    final body = Map<String, dynamic>.from(payload);
    body.putIfAbsent('client_uuid', () => id);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    if (tsAsTs) {
      body.putIfAbsent('ts', () => nowIso);       // tracking endpoint reads "ts"
    } else {
      body.putIfAbsent('client_ts', () => nowIso); // record endpoints read "client_ts"
    }
    await d.insert('outbox', {
      'client_uuid': id, 'endpoint': endpoint, 'payload': jsonEncode(body),
      'label': label, 'created_at': nowIso, 'status': 0,
    });
  }

  static Future<List<Map<String, Object?>>> pending() async =>
      (await _database).query('outbox', where: 'status=0', orderBy: 'id ASC', limit: 200);
  static Future<int> count(int status) async {
    final r = await (await _database).rawQuery('SELECT COUNT(*) c FROM outbox WHERE status=?', [status]);
    return (r.first['c'] as int?) ?? 0;
  }
  static Future<void> setStatus(int id, int status, [String? err]) async =>
      (await _database).update('outbox', {'status': status, 'last_error': err}, where: 'id=?', whereArgs: [id]);
  static Future<void> bump(int id, String err) async =>
      (await _database).rawUpdate('UPDATE outbox SET attempts=attempts+1, last_error=? WHERE id=?', [err, id]);
}

/* ----------------------------- Sync service ----------------------------- */
class Sync {
  Sync._();
  static final Sync I = Sync._();
  bool _running = false;
  DateTime? lastSync;
  final pending = ValueNotifier<int>(0);
  final failed = ValueNotifier<int>(0);
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(const Duration(minutes: 2), (_) => flush());
    Connectivity().onConnectivityChanged.listen((_) => flush()); // try as soon as network returns
    refresh();
  }
  Future<void> refresh() async { pending.value = await LocalDb.count(0); failed.value = await LocalDb.count(2); }

  Future<bool> _serverUp() async {
    try {
      final r = await http.get(Uri.parse('$apiBase/health')).timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) { return false; }
  }

  Future<void> flush() async {
    if (_running || Api.token == null) return;
    _running = true;
    try {
      if (!await _serverUp()) return;                 // server off (e.g. overnight) -> keep queued
      for (final row in await LocalDb.pending()) {
        final id = row['id'] as int;
        final endpoint = row['endpoint'] as String;
        final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        try {
          final r = await Api.post(endpoint, payload).timeout(const Duration(seconds: 20));
          if (r.statusCode >= 200 && r.statusCode < 300) {
            await LocalDb.setStatus(id, 1);                          // delivered (server de-dupes replays)
          } else if (r.statusCode == 401 || r.statusCode == 403) {
            break;                                                   // auth/consent issue -> retry after fix
          } else if (r.statusCode >= 400 && r.statusCode < 500) {
            await LocalDb.setStatus(id, 2, 'HTTP ${r.statusCode}: ${r.body}'); // permanent -> park
          } else {
            await LocalDb.bump(id, 'HTTP ${r.statusCode}'); break;             // server error -> later
          }
        } catch (e) { await LocalDb.bump(id, '$e'); break; }                   // network drop -> later
      }
      lastSync = DateTime.now();
    } finally {
      _running = false;
      await refresh();
    }
  }
}

/* ----------------------------- App shell ----------------------------- */
class WineFlowApp extends StatelessWidget {
  const WineFlowApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'WineFlow',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F3864)), useMaterial3: true),
        home: const Gate(),
      );
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}
class _GateState extends State<Gate> {
  bool loading = true;
  @override
  void initState() {
    super.initState();
    Api.loadToken().then((_) { Sync.I.start(); setState(() => loading = false); });
  }
  @override
  Widget build(BuildContext c) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Api.token == null ? const LoginScreen() : const HomeScreen();
  }
}

/* ----------------------------- Login / Register ----------------------------- */
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final mobile = TextEditingController(), otp = TextEditingController(),
      name = TextEditingController(), emp = TextEditingController();
  bool registerMode = false, otpSent = false;
  String msg = '';
  String _err(http.Response r) { try { return jsonDecode(r.body)['error'] ?? 'error'; } catch (_) { return 'error ${r.statusCode}'; } }

  Future<void> sendOtp(String purpose) async {
    try {
      final r = await Api.post('/api/v1/register/otp', {'mobile': mobile.text, 'purpose': purpose});
      setState(() { otpSent = r.statusCode == 200; msg = r.statusCode == 200 ? 'OTP sent' : _err(r); });
    } catch (_) { setState(() => msg = 'Cannot reach server. Check your connection.'); }
  }
  Future<void> doRegister() async {
    final r = await Api.post('/api/v1/register',
        {'mobile': mobile.text, 'otp': otp.text, 'name': name.text, 'emp_code': emp.text});
    setState(() => msg = r.statusCode == 201 ? 'Submitted — waiting for manager approval.' : _err(r));
  }
  Future<void> doLogin() async {
    final r = await Api.post('/api/v1/register/login', {'mobile': mobile.text, 'otp': otp.text, 'device_id': 'app'});
    if (r.statusCode == 200) {
      await Api.saveToken(jsonDecode(r.body)['token']);
      Sync.I.flush();
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
    } else { setState(() => msg = _err(r)); }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(registerMode ? 'Register' : 'WineFlow Login'),
            backgroundColor: const Color(0xFF1F3864), foregroundColor: Colors.white),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          TextField(controller: mobile, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile number (10 digits)')),
          if (registerMode) TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
          if (registerMode) TextField(controller: emp, decoration: const InputDecoration(labelText: 'Employee code')),
          if (otpSent) TextField(controller: otp, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Enter OTP')),
          const SizedBox(height: 16),
          if (!otpSent) FilledButton(onPressed: () => sendOtp(registerMode ? 'register' : 'login'), child: const Text('Send OTP')),
          if (otpSent) FilledButton(onPressed: registerMode ? doRegister : doLogin, child: Text(registerMode ? 'Register' : 'Login')),
          TextButton(onPressed: () => setState(() { registerMode = !registerMode; otpSent = false; msg = ''; }),
              child: Text(registerMode ? 'Have an account? Login' : 'New user? Register')),
          Text(msg, style: const TextStyle(color: Color(0xFFB26A00))),
        ])),
      );
}

/* ----------------------------- Home / dashboard ----------------------------- */
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  Timer? gpsTimer;
  String gpsStatus = 'starting…';

  @override
  void initState() {
    super.initState();
    _ensureConsent();
    _startTracking();
    Sync.I.flush();
  }
  @override
  void dispose() { gpsTimer?.cancel(); super.dispose(); }

  // DPDP: a newly approved user must grant location/selfie consent once.
  Future<void> _ensureConsent() async {
    try {
      final r = await Api.get('/api/v1/consent/me');
      if (r.statusCode == 200 && jsonDecode(r.body)['active'] == true) return;
    } catch (_) { return; }
    if (!mounted) return;
    final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => AlertDialog(
      title: const Text('Location & photo consent'),
      content: const Text('WineFlow records your work location and photos during '
          'working hours to verify field visits. You can withdraw consent anytime. Allow?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
      ],
    ));
    if (ok == true) { await Api.post('/api/v1/consent', {'granted': true, 'purpose': 'location+selfie'}); }
  }

  Future<Position?> _pos() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    return Geolocator.getCurrentPosition();
  }
  void _startTracking() {
    _ping(); // capture once immediately, then every 5 minutes
    gpsTimer = Timer.periodic(const Duration(minutes: 5), (_) => _ping());
  }
  Future<void> _ping() async {
    final p0 = await _pos();
    if (p0 == null) { setState(() => gpsStatus = 'location permission needed'); return; }
    await LocalDb.enqueue('/api/v1/tracking/ping',
        {'lat': p0.latitude, 'lng': p0.longitude, 'speed': p0.speed, 'accuracy_m': p0.accuracy},
        'GPS ping', tsAsTs: true);
    Sync.I.flush();
    if (mounted) setState(() => gpsStatus = 'tracking (queued ${TimeOfDay.now().format(context)})');
  }

  Future<void> _logout() async {
    await Api.clear();
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext c) {
    final tiles = [
      _Tile('Attendance', Icons.location_on, () => _go(const AttendanceScreen())),
      _Tile('Outlet Visit', Icons.store, () => _go(const VisitScreen())),
      _Tile('Order Booking', Icons.receipt_long, () => _go(const OrderScreen())),
      _Tile('Collection', Icons.payments, () => _go(const CollectionScreen())),
      _Tile('Daily Report', Icons.assignment, () => _go(const DailyReportScreen())),
      _Tile('Expense Claim', Icons.request_quote, () => _go(const ExpenseScreen())),
      _Tile('Apply Leave', Icons.event_busy, () => _go(const LeaveScreen())),
      _Tile('New Outlet', Icons.add_business, () => _go(const NewOutletScreen())),
      _Tile('My Route', Icons.alt_route, () => _go(const RouteScreen())),
      _Tile('My Team', Icons.groups, () => _go(const TeamScreen())),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('WineFlow'), backgroundColor: const Color(0xFF1F3864), foregroundColor: Colors.white,
          actions: [IconButton(onPressed: _logout, icon: const Icon(Icons.logout))]),
      body: Column(children: [
        const _SyncBar(),
        Container(width: double.infinity, color: const Color(0xFFEAF1F8), padding: const EdgeInsets.all(10),
            child: Text('GPS: $gpsStatus', style: const TextStyle(color: Color(0xFF1F3864), fontSize: 12))),
        Expanded(child: GridView.count(crossAxisCount: 2, padding: const EdgeInsets.all(16), children: tiles)),
      ]),
    );
  }
  void _go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
}

/// Banner showing how many records are waiting to upload + a manual sync button.
class _SyncBar extends StatelessWidget {
  const _SyncBar();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: Sync.I.pending,
        builder: (_, n, __) {
          final synced = n == 0;
          return Container(
            width: double.infinity, color: synced ? const Color(0xFFE6F4EA) : const Color(0xFFFFF3E0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Icon(synced ? Icons.cloud_done : Icons.cloud_upload, size: 18,
                  color: synced ? const Color(0xFF2E7D32) : const Color(0xFFB26A00)),
              const SizedBox(width: 8),
              Expanded(child: Text(
                synced ? 'All data synced to server' : '$n record(s) waiting — will upload when server is online',
                style: TextStyle(fontSize: 12, color: synced ? const Color(0xFF2E7D32) : const Color(0xFFB26A00)))),
              TextButton(onPressed: () => Sync.I.flush(), child: const Text('Sync now')),
            ]),
          );
        },
      );
}

class _Tile extends StatelessWidget {
  final String label; final IconData icon; final VoidCallback onTap;
  const _Tile(this.label, this.icon, this.onTap);
  @override
  Widget build(BuildContext c) => Card(margin: const EdgeInsets.all(8),
        child: InkWell(onTap: onTap, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 44, color: const Color(0xFF2E75B6)), const SizedBox(height: 10),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ])));
}

/* shared "saved offline" feedback */
void _saved(BuildContext c, String what) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$what saved — will upload when online')));
  Sync.I.flush();
}

/* ----------------------------- Attendance ----------------------------- */
class AttendanceScreen extends StatefulWidget { const AttendanceScreen({super.key}); @override State<AttendanceScreen> createState()=>_A(); }
class _A extends State<AttendanceScreen> {
  Future<void> punch(String type) async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    final p0 = await Geolocator.getCurrentPosition();
    await LocalDb.enqueue('/api/v1/attendance/punch',
        {'type': type, 'lat': p0.latitude, 'lng': p0.longitude, 'accuracy_m': p0.accuracy}, 'Attendance $type');
    if (mounted) _saved(context, 'Check-$type');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Attendance')),
        body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
          FilledButton.icon(onPressed: () => punch('IN'), icon: const Icon(Icons.login), label: const Text('Check-In (GPS)')),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => punch('OUT'), icon: const Icon(Icons.logout), label: const Text('Check-Out (GPS)')),
          const SizedBox(height: 16),
          const Text('Works offline. Your check-in time is preserved even if upload happens later.',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ])),
      );
}

/* ----------------------------- Outlet Visit ----------------------------- */
class VisitScreen extends StatefulWidget { const VisitScreen({super.key}); @override State<VisitScreen> createState()=>_V(); }
class _V extends State<VisitScreen> {
  final outletId = TextEditingController(text: '1');
  String outcome = 'Order taken';
  String? photoRef; String photoStatus = '';

  Future<void> takePhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 60);
      if (x == null) return;
      setState(() => photoStatus = 'uploading…');
      final bytes = await x.readAsBytes();
      final b64 = base64Encode(bytes);
      // upload to central Drive store when online; visit still saves if this fails
      final r = await Api.post('/api/v1/photos', {'kind': 'outlet', 'data_base64': b64});
      if (r.statusCode == 201) {
        photoRef = jsonDecode(r.body)['drive_file_id'];
        setState(() => photoStatus = 'photo attached');
      } else {
        setState(() => photoStatus = 'photo needs internet + Drive setup');
      }
    } catch (_) { setState(() => photoStatus = 'photo capture failed'); }
  }

  Future<void> save() async {
    Position? p0; try { p0 = await Geolocator.getCurrentPosition(); } catch (_) {}
    await LocalDb.enqueue('/api/v1/visits',
        {'outlet_id': int.tryParse(outletId.text), 'lat': p0?.latitude, 'lng': p0?.longitude,
         'outcome': outcome, if (photoRef != null) 'shelf_photo_ref': photoRef}, 'Visit');
    if (mounted) _saved(context, 'Visit');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Outlet Visit')),
        body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
          TextField(controller: outletId, decoration: const InputDecoration(labelText: 'Outlet ID')),
          DropdownButtonFormField(value: outcome,
              items: ['Order taken','No order','Closed outlet','Competitor dominance','Payment issue']
                  .map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>outcome=v as String)),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: takePhoto, icon: const Icon(Icons.camera_alt), label: const Text('Take shelf photo')),
          if (photoStatus.isNotEmpty) Text(photoStatus, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Save Visit (GPS)')),
        ])),
      );
}

/* ----------------------------- Order Booking ----------------------------- */
class OrderScreen extends StatefulWidget { const OrderScreen({super.key}); @override State<OrderScreen> createState()=>_O(); }
class _O extends State<OrderScreen> {
  final outlet = TextEditingController(text: '1'), dist = TextEditingController(text: '1'),
      sku = TextEditingController(text: '1'), qty = TextEditingController(text: '12'),
      state = TextEditingController(text: 'MH');
  Future<void> submit() async {
    await LocalDb.enqueue('/api/v1/orders', {
      'outlet_id': int.tryParse(outlet.text), 'distributor_id': int.tryParse(dist.text),
      'state': state.text, 'lines': [{'sku_id': int.tryParse(sku.text), 'qty': int.tryParse(qty.text)}],
    }, 'Order');
    if (mounted) _saved(context, 'Order');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Order Booking')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          TextField(controller: state, decoration: const InputDecoration(labelText: 'State (e.g. MH)')),
          TextField(controller: outlet, decoration: const InputDecoration(labelText: 'Outlet ID')),
          TextField(controller: dist, decoration: const InputDecoration(labelText: 'Distributor ID')),
          TextField(controller: sku, decoration: const InputDecoration(labelText: 'SKU ID')),
          TextField(controller: qty, decoration: const InputDecoration(labelText: 'Quantity')),
          const SizedBox(height: 16),
          FilledButton(onPressed: submit, child: const Text('Submit Order')),
        ])),
      );
}

/* ----------------------------- Collection ----------------------------- */
class CollectionScreen extends StatefulWidget { const CollectionScreen({super.key}); @override State<CollectionScreen> createState()=>_Co(); }
class _Co extends State<CollectionScreen> {
  final dist = TextEditingController(text: '1'), amt = TextEditingController(), utr = TextEditingController();
  String mode = 'UPI';
  Future<void> save() async {
    await LocalDb.enqueue('/api/v1/collections',
        {'distributor_id': int.tryParse(dist.text), 'amount': num.tryParse(amt.text), 'mode': mode, 'utr': utr.text}, 'Collection');
    if (mounted) _saved(context, 'Collection');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Collection')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          TextField(controller: dist, decoration: const InputDecoration(labelText: 'Distributor ID')),
          TextField(controller: amt, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
          DropdownButtonFormField(value: mode,
              items: ['NEFT','RTGS','UPI','Cheque','Cash'].map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>mode=v as String)),
          TextField(controller: utr, decoration: const InputDecoration(labelText: 'UTR / reference')),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Record')),
        ])),
      );
}

/* ===================== Increment 5 — employee submissions ===================== */

/* ----------------------------- Daily Report ----------------------------- */
class DailyReportScreen extends StatefulWidget { const DailyReportScreen({super.key}); @override State<DailyReportScreen> createState()=>_DR(); }
class _DR extends State<DailyReportScreen> {
  final summary = TextEditingController();
  final orders = TextEditingController(text: '0');
  final collection = TextEditingController(text: '0');
  final remarks = TextEditingController();
  Future<void> save() async {
    await LocalDb.enqueue('/api/v1/dailyreports', {
      'summary': summary.text,
      'orders_count': int.tryParse(orders.text) ?? 0,
      'collection_amount': num.tryParse(collection.text) ?? 0,
      'remarks': remarks.text,
    }, 'Daily Report');
    if (mounted) _saved(context, 'Daily report');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Daily Report')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          TextField(controller: summary, maxLines: 3, decoration: const InputDecoration(labelText: 'Summary of the day')),
          TextField(controller: orders, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Orders taken')),
          TextField(controller: collection, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Collection amount')),
          TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks')),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Submit Report')),
        ])),
      );
}

/* ----------------------------- Expense Claim ----------------------------- */
class ExpenseScreen extends StatefulWidget { const ExpenseScreen({super.key}); @override State<ExpenseScreen> createState()=>_EX(); }
class _EX extends State<ExpenseScreen> {
  final amount = TextEditingController();
  final desc = TextEditingController();
  String category = 'Travel';
  Future<void> save() async {
    await LocalDb.enqueue('/api/v1/expenses',
        {'category': category, 'amount': num.tryParse(amount.text), 'description': desc.text}, 'Expense');
    if (mounted) _saved(context, 'Expense claim');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Expense Claim')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          DropdownButtonFormField(value: category,
              items: ['Travel','Food','Lodging','Misc'].map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>category=v as String)),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
          TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Submit Claim')),
        ])),
      );
}

/* ----------------------------- Leave Request ----------------------------- */
class LeaveScreen extends StatefulWidget { const LeaveScreen({super.key}); @override State<LeaveScreen> createState()=>_LV(); }
class _LV extends State<LeaveScreen> {
  DateTime from = DateTime.now(), to = DateTime.now();
  final reason = TextEditingController();
  String type = 'Casual';
  Future<void> pick(bool isFrom) async {
    final d = await showDatePicker(context: context, initialDate: isFrom ? from : to,
        firstDate: DateTime(2024), lastDate: DateTime(2030));
    if (d != null) setState(() { if (isFrom) from = d; else to = d; });
  }
  Future<void> save() async {
    await LocalDb.enqueue('/api/v1/leave', {
      'from_date': from.toIso8601String().substring(0, 10),
      'to_date': to.toIso8601String().substring(0, 10),
      'leave_type': type, 'reason': reason.text,
    }, 'Leave');
    if (mounted) _saved(context, 'Leave request');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Apply Leave')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          ListTile(title: const Text('From date'), subtitle: Text(from.toIso8601String().substring(0,10)), trailing: const Icon(Icons.calendar_today), onTap: ()=>pick(true)),
          ListTile(title: const Text('To date'), subtitle: Text(to.toIso8601String().substring(0,10)), trailing: const Icon(Icons.calendar_today), onTap: ()=>pick(false)),
          DropdownButtonFormField(value: type,
              items: ['Casual','Sick','Earned'].map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>type=v as String)),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Apply')),
        ])),
      );
}

/* ----------------------------- New Outlet Request ----------------------------- */
class NewOutletScreen extends StatefulWidget { const NewOutletScreen({super.key}); @override State<NewOutletScreen> createState()=>_NO(); }
class _NO extends State<NewOutletScreen> {
  final name = TextEditingController();
  final owner = TextEditingController();
  final state = TextEditingController(text: 'MH');
  String type = 'Wine Shop', potential = 'Medium';
  Future<void> save() async {
    Position? p0; try { p0 = await Geolocator.getCurrentPosition(); } catch (_) {}
    await LocalDb.enqueue('/api/v1/masters/outlets/request', {
      'name': name.text, 'outlet_type': type, 'state': state.text,
      'owner_name': owner.text, 'potential': potential,
      'lat': p0?.latitude, 'lng': p0?.longitude,
    }, 'New Outlet');
    if (mounted) _saved(context, 'New-outlet request');
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('New Outlet Request')),
        body: Padding(padding: const EdgeInsets.all(20), child: ListView(children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Outlet name')),
          DropdownButtonFormField(value: type,
              items: ['Wine Shop','Restaurant','Hotel','Bar','Club'].map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>type=v as String)),
          TextField(controller: state, decoration: const InputDecoration(labelText: 'State (e.g. MH)')),
          TextField(controller: owner, decoration: const InputDecoration(labelText: 'Owner name')),
          DropdownButtonFormField(value: potential,
              items: ['High','Medium','Low'].map((e)=>DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v)=>setState(()=>potential=v as String)),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('Submit Request (with GPS)')),
        ])),
      );
}

/* ----------------------------- My Route (assigned beat) ----------------------------- */
class RouteScreen extends StatefulWidget { const RouteScreen({super.key}); @override State<RouteScreen> createState()=>_RT(); }
class _RT extends State<RouteScreen> {
  List outlets = []; String msg = 'Loading…';
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final r = await Api.get('/api/v1/beats/my-route');
      if (r.statusCode == 200) { setState(() { outlets = jsonDecode(r.body)['route'] ?? []; msg = outlets.isEmpty ? 'No outlets assigned to your beat yet.' : ''; }); }
      else { setState(() => msg = 'Could not load route (needs internet).'); }
    } catch (_) { setState(() => msg = 'Offline — connect to see your route.'); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('My Route')),
        body: outlets.isEmpty
            ? Center(child: Text(msg, style: const TextStyle(color: Colors.grey)))
            : ListView(children: outlets.map<Widget>((o) => ListTile(
                leading: const Icon(Icons.store, color: Color(0xFF2E75B6)),
                title: Text(o['name'] ?? ''), subtitle: Text('${o['outlet_type'] ?? ''} · ${o['potential'] ?? ''}'),
                trailing: (o['lat'] != null)
                    ? IconButton(icon: const Icon(Icons.map), onPressed: () {}) : null,
              )).toList()),
      );
}

/* ===================== Sales hierarchy — My Team (supervisor view) ===================== */
class TeamScreen extends StatefulWidget { const TeamScreen({super.key}); @override State<TeamScreen> createState()=>_TM(); }
class _TM extends State<TeamScreen> {
  List team = []; String msg = 'Loading…';
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final r = await Api.get('/api/v1/team');
      if (r.statusCode == 200) {
        setState(() { team = jsonDecode(r.body)['team'] ?? []; msg = team.isEmpty ? 'You have no team members (field level).' : ''; });
      } else { setState(() => msg = 'Could not load team (needs internet).'); }
    } catch (_) { setState(() => msg = 'Offline — connect to view your team.'); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('My Team')),
        body: team.isEmpty
            ? Center(child: Text(msg, style: const TextStyle(color: Colors.grey)))
            : ListView(children: team.map<Widget>((m) {
                final ci = m['checked_in'] != null;
                return ListTile(
                  leading: CircleAvatar(backgroundColor: ci ? const Color(0xFF2E7D32) : Colors.grey,
                      child: Text('L${m['sales_level'] ?? ''}', style: const TextStyle(color: Colors.white, fontSize: 12))),
                  title: Text(m['name'] ?? ''),
                  subtitle: Text('${m['emp_code'] ?? ''} · orders today: ${m['orders_today'] ?? 0} · ${ci ? 'checked in' : 'absent'}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => TeamMemberScreen(userId: m['id'], name: m['name'] ?? ''))),
                );
              }).toList()),
      );
}

class TeamMemberScreen extends StatefulWidget {
  final int userId; final String name;
  const TeamMemberScreen({super.key, required this.userId, required this.name});
  @override State<TeamMemberScreen> createState()=>_TMM();
}
class _TMM extends State<TeamMemberScreen> {
  Map daily = {}; List timeline = []; String msg = 'Loading…';
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final d = await Api.get('/api/v1/team/member/${widget.userId}/daily');
      final t = await Api.get('/api/v1/team/member/${widget.userId}/timeline');
      if (d.statusCode == 200) {
        setState(() { daily = jsonDecode(d.body); timeline = (t.statusCode==200)? (jsonDecode(t.body)['timeline'] ?? []) : []; msg = ''; });
      } else if (d.statusCode == 403) { setState(() => msg = 'This person is not in your team.'); }
      else { setState(() => msg = 'Could not load (needs internet).'); }
    } catch (_) { setState(() => msg = 'Offline — connect to view.'); }
  }
  String _t(v) => v == null ? '—' : DateTime.parse(v).toLocal().toString().substring(11, 16);
  @override
  Widget build(BuildContext c) {
    if (msg.isNotEmpty) return Scaffold(appBar: AppBar(title: Text(widget.name)), body: Center(child: Text(msg, style: const TextStyle(color: Colors.grey))));
    final icon = {'checkin':'🟢','checkout':'🔴','visit':'🏪','order':'🧾','collection':'💰'};
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          _stat('Check-in', _t(daily['check_in'])), _stat('Check-out', _t(daily['check_out'])),
          _stat('Hours', '${daily['working_hours'] ?? '—'}'), _stat('Distance', '${daily['distance_km'] ?? 0} km'),
          _stat('GPS pts', '${daily['gps_points'] ?? 0}'), _stat('Outlets', '${(daily['visited_outlets'] ?? []).length}'),
        ]),
        const SizedBox(height: 16),
        const Text('Timeline', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1F3864))),
        ...timeline.map<Widget>((e) => ListTile(dense: true,
            leading: Text(icon[e['type']] ?? '•', style: const TextStyle(fontSize: 18)),
            title: Text(e['label'] ?? ''), trailing: Text(_t(e['ts'])))),
        if (timeline.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No activity today', style: TextStyle(color: Colors.grey))),
      ]),
    );
  }
  Widget _stat(String k, String v) => Container(width: 150, padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFEAF1F8), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 11, color: Color(0xFF5A6473))),
        Text(v, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1F3864))),
      ]));
}
