import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

// Inisialisasi instance plugin notifikasi lokal sebagai objek global untuk aksesibilitas sistem
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  try {
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings, 
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint("Notifikasi diklik: ${response.payload}");
      },
    );
    debugPrint("Sistem Notifikasi Lokal Berhasil Diinisialisasi.");
  } catch (e) {
    debugPrint("Gagal menginisialisasi notifikasi lokal: $e");
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FOUNTAINE App',
      theme: ThemeData.dark(), 
      home: const AuthGate(), 
    );
  }
}

// ====================================================================
// SUB-SISTEM AUTENTIKASI DAN PROSEDUR PERMINTAAN IZIN SISTEM OPERASI
// ====================================================================
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _mintaIzinDanLogin();
  }

  // Menjalankan prosedur asinkronus untuk alokasi hak akses notifikasi dan otentikasi Firebase
  Future<void> _mintaIzinDanLogin() async {
    // 1. Prosedur permintaan hak akses notifikasi pada level sistem operasi (Runtime Permission)
    try {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
              
      if (androidImplementation != null) {
        await androidImplementation.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint("Gagal meminta izin notifikasi: $e");
    }

    // 2. Anonymous Authentication ke Firebase Server
    try {
      // Ambil instance user saat ini dari cache lokal Firebase
      User? currentUser = FirebaseAuth.instance.currentUser;

      if (currentUser == null) {
        debugPrint("Sesi lokal kosong. Memulai proses otentikasi anonim baru...");
        
        // Eksekusi sign-in anonim
        UserCredential userCredential = await FirebaseAuth.instance.signInAnonymously();
        
        debugPrint("Otentikasi anonim BARU berhasil. UID: ${userCredential.user?.uid}");
      } else {
        // Jika session masih ada di memori lokal device, reload untuk memastikan akun belum di-delete di console
        debugPrint("Sesi lokal ditemukan. Memvalidasi token ke Firebase Server...");
        await currentUser.reload();
        
        // Ambil data user terbaru setelah di-reload
        currentUser = FirebaseAuth.instance.currentUser;
        debugPrint("Sesi lama VALID dan digunakan kembali. UID: ${currentUser?.uid}");
      }
      
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Kegagalan proses otentikasi: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.teal),
              SizedBox(height: 16),
              Text("Menginisialisasi koneksi aman Firebase...", style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 60),
                const SizedBox(height: 16),
                const Text("Kegagalan Otentikasi Keamanan Sistem", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _errorMessage = null;
                    });
                    // Mengeksekusi ulang fungsi inisialisasi jaringan
                    _mintaIzinDanLogin();
                  },
                  child: const Text("Coba Kembali"),
                )
              ],
            ),
          ),
        ),
      );
    }

    return const DashboardScreen();
  }
}

// ====================================================================
// ANTARMUKA UTAMA (DASHBOARD) MONITORING DATA TELEMETRI DAN AKTUASI LOGIKA
// ====================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DatabaseReference _sensorRef = FirebaseDatabase.instance.ref('/Fountaine');
  final DatabaseReference _controlRef = FirebaseDatabase.instance.ref('/Fountaine_Control');
  
  // Variabel untuk menampung langganan aliran data guna menghindari kebocoran memori (Memory Leak)
  StreamSubscription<DatabaseEvent>? _sensorSubscription;

  // Variabel penanda (Flags) untuk mengontrol dan membatasi redundansi pengiriman notifikasi
  bool _isNotifPhSent = false;
  bool _isNotifAirSent = false;

  @override
  void initState() {
    super.initState();
    _initNotificationListener();
  }

  @override
  void dispose() {
    // Membatalkan langganan aliran data saat siklus hidup widget berakhir (Dispose State)
    _sensorSubscription?.cancel();
    super.dispose();
  }

  // --- SUB-SISTEM EVALUASI PARAMETER KONDISI UNTUK PEMICU NOTIFIKASI ---
  void _initNotificationListener() {
    _sensorSubscription = _sensorRef.onValue.listen((DatabaseEvent event) {
      if (event.snapshot.value != null) {
        final Map<dynamic, dynamic> data = event.snapshot.value as Map<dynamic, dynamic>;
        
        final double ph = (data['pH'] ?? 7.0).toDouble();
        final double volume = (data['VolumeAir'] ?? 5.0).toDouble();

        // 1. Logika Pemicu Notifikasi Ambang Batas pH (Rentang Optimal: 5.5 - 6.5)
        if (ph < 5.5 || ph > 6.5) {
          if (!_isNotifPhSent) {
            _tampilkanNotifikasi(
              1,
              '⚠️ Peringatan Kondisi pH Air!',
              'Nilai pH sistem hidroponik terdeteksi di luar batas optimal: ${ph.toStringAsFixed(1)}. Segera lakukan pengecekan.',
            );
            _isNotifPhSent = true; 
          }
        } else {
          _isNotifPhSent = false; 
        }

        // 2. Logika Pemicu Notifikasi Volume Air Kritis (Batas Minimum < 2.0 Liter)
        if (volume < 2.0) {
          if (!_isNotifAirSent) {
            _tampilkanNotifikasi(
              2,
              '🚨 Peringatan Volume Air Kritis!',
              'Volume air tandon tersisa ${volume.toStringAsFixed(1)} Liter. Segera lakukan pengisian ulang.',
            );
            _isNotifAirSent = true;
          }
        } else {
          _isNotifAirSent = false;
        }
      }
    });
  }

  // Prosedur pemanggilan jalur interupsi notifikasi lokal
  Future<void> _tampilkanNotifikasi(int id, String title, String body) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'fountaine_channel_id',
      'Notifikasi Fountaine',
      channelDescription: 'Saluran peringatan parameter sistem FOUNTAINE',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'ticker',
      color: Colors.teal,
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      platformChannelSpecifics,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FOUNTAINE Monitor & Control'),
        centerTitle: true,
        backgroundColor: Colors.teal[800],
        actions: [
          IconButton(
            icon: const Icon(Icons.verified_user, color: Colors.greenAccent),
            tooltip: 'Secured with Anonymous Auth',
            onPressed: () {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Sistem Terautentikasi. UID: $uid')),
              );
            },
          )
        ],
      ),
      body: StreamBuilder(
        stream: _sensorRef.onValue, 
        builder: (context, AsyncSnapshot<DatabaseEvent> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text('Error: ${snapshot.error}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
              ),
            );
          }

          if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
            final Map<dynamic, dynamic> data = snapshot.data!.snapshot.value as Map<dynamic, dynamic>;

            final double volume = (data['VolumeAir'] ?? 0.0).toDouble();
            final double suhu = (data['Suhu'] ?? 0.0).toDouble();
            final double tds = (data['TDS'] ?? 0.0).toDouble();
            final double ph = (data['pH'] ?? 0.0).toDouble();
            final String statusUV = data['StatusUV'] ?? "MATI";

            return SafeArea( 
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSensorCard('VOLUME AIR', '${volume.toStringAsFixed(1)} Liter', Colors.purpleAccent),
                    const SizedBox(height: 12),
                    _buildSensorCard('SUHU AIR', '${suhu.toStringAsFixed(1)} °C', Colors.redAccent),
                    const SizedBox(height: 12),
                    _buildSensorCard('NUTRISI (TDS)', '${tds.toStringAsFixed(0)} PPM', Colors.amberAccent),
                    const SizedBox(height: 12),
                    _buildSensorCard('TINGKAT KEASAMAN (pH)', ph.toStringAsFixed(1), Colors.blueAccent),
                    const SizedBox(height: 20),

                    Text(
                      'PANEL KENDALI MANUAL AKTUATOR LAMPU UV', 
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal[200], letterSpacing: 1.2)
                    ),
                    const SizedBox(height: 8),

                    // Konstruksi StreamBuilder untuk sinkronisasi state kontrol manual
                    StreamBuilder(
                      stream: _controlRef.onValue,
                      builder: (context, AsyncSnapshot<DatabaseEvent> ctrlSnapshot) {
                        String modeLampu = "OTOMATIS";
                        String statusManual = "MATI";

                        if (ctrlSnapshot.hasData && ctrlSnapshot.data!.snapshot.value != null) {
                          final Map<dynamic, dynamic> ctrlData = ctrlSnapshot.data!.snapshot.value as Map<dynamic, dynamic>;
                          modeLampu = ctrlData['Mode_Lampu'] ?? "OTOMATIS";
                          statusManual = ctrlData['Status_Manual'] ?? "MATI";
                        }

                        bool isManualMode = (modeLampu == "MANUAL");
                        bool isManualSwitchOn = (statusManual == "MENYALA");

                        return Card(
                          color: Colors.grey[900],
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: Colors.teal, width: 1),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text('Mode Kerja Sistem', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                          Text('Status Configuration: $modeLampu', style: TextStyle(color: Colors.tealAccent[400], fontSize: 12)),
                                        ],
                                      ),
                                    ),
                                    Switch(
                                      value: isManualMode,
                                      activeThumbColor: Colors.tealAccent,
                                      onChanged: (val) {
                                        _controlRef.update({
                                          'Mode_Lampu': val ? 'MANUAL' : 'OTOMATIS',
                                        });
                                      },
                                    ),
                                  ],
                                ),
                                const Divider(color: Colors.grey, height: 20),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text('Saklar Lampu Manual', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                          Text(
                                            isManualMode ? 'Status Perintah Aktual: $statusManual' : 'Aktifkan Mode Manual untuk membuka akses kontrol',
                                            style: TextStyle(color: isManualMode ? Colors.purpleAccent : Colors.grey, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Switch(
                                      value: isManualSwitchOn,
                                      activeThumbColor: Colors.purpleAccent,
                                      onChanged: isManualMode ? (val) {
                                        _controlRef.update({
                                          'Status_Manual': val ? 'MENYALA' : 'MATI',
                                        });
                                      } : null,
                                    ),
                                  ],
                                ),
                                const Divider(color: Colors.grey, height: 20),
                                
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.wb_incandescent_rounded, size: 16, color: Colors.grey),
                                    const SizedBox(width: 6),
                                    const Text('Umpan Balik Hardware (Real-time): ', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                    Text(
                                      statusUV, 
                                      style: TextStyle(
                                        color: statusUV == "MENYALA" ? Colors.purpleAccent : Colors.white60,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12
                                      )
                                    ),
                                  ],
                                )
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 20),

                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.green),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("PANDUAN OPERASIONAL", style: TextStyle(fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text("• Apabila parameter pH terdeteksi di bawah 5.5, tambahkan cairan pH Up.\n• Apabila parameter pH terdeteksi di atas 6.5, tambahkan cairan pH Down.", style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return const Center(
            child: Text('Node Firebase Database Kosong.\nPastikan sirkuit mikrokontroler telah mentransmisikan data.', textAlign: TextAlign.center),
          );
        },
      ),
    );
  }

  Widget _buildSensorCard(String title, String value, Color color) {
    return Card(
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontSize: 14, color: Colors.grey)),
            Text(value, style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}