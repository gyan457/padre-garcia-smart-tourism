import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const PadreGarciaTourismApp());
}

// ==========================================
// THEME CONSTANTS (EMERALD, FOREST & AMBER GOLD)
// ==========================================
class AppColors {
  static const primaryDark = Color(0xFF041A13);
  static const primary = Color(0xFF0F4C3A);
  static const primaryLight = Color(0xFF1E785D);
  static const accent = Color(0xFFF59E0B);
  static const accentBright = Color(0xFFFBBF24);
  static const accentSoft = Color(0xFFFEF3C7);
  static const bgLight = Color(0xFFEEF3F0);
  static const cardWhite = Colors.white;
  static const textDark = Color(0xFF0F172A);
  static const textMuted = Color(0xFF64748B);
}

typedef TourismItem = Map<String, dynamic>;

// ==========================================
// STYLIZED BRAND WIDGET: cAIttle (Emphasizing AI)
// ==========================================
class CaittleBrandText extends StatelessWidget {
  final double fontSize;
  final Color baseColor;
  final FontWeight weight;

  const CaittleBrandText({
    super.key,
    this.fontSize = 18,
    this.baseColor = Colors.white,
    this.weight = FontWeight.w900,
  });

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          fontFamily: 'Roboto',
          letterSpacing: 0.4,
        ),
        children: [
          TextSpan(text: 'c', style: TextStyle(color: baseColor)),
          TextSpan(
            text: 'AI',
            style: TextStyle(
              color: AppColors.accentBright,
              fontWeight: FontWeight.w900,
              shadows: [
                Shadow(
                  color: AppColors.accent.withValues(alpha: 0.65),
                  blurRadius: 10,
                ),
              ],
            ),
          ),
          TextSpan(text: 'ttle', style: TextStyle(color: baseColor)),
        ],
      ),
    );
  }
}

// ==========================================
// BACKEND & STATE MANAGEMENT LAYER
// ==========================================
class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static Future<bool> login(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> register(String name, String email, String password) async {
    try {
      UserCredential creds = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      await creds.user?.updateDisplayName(name);
      return true;
    } catch (e) {
      return false;
    }
  }

  static String getName(String email) {
    final user = _auth.currentUser;
    if (user != null && user.displayName != null && user.displayName!.isNotEmpty) {
      return user.displayName!;
    }
    if (user != null && user.email == email) {
      return user.email!.split('@').first;
    }
    return email.split('@').first;
  }

  // Admin access is granted only by Firebase Admin SDK custom claims.
  // Never trust an email address checked only inside the app.
  static Future<bool> isAdmin(String email) async {
    final user = _auth.currentUser;
    if (user == null || user.email?.toLowerCase() != email.toLowerCase()) return false;
    final token = await user.getIdTokenResult(true);
    return token.claims?['admin'] == true;
  }
}

class TourismRepository extends ChangeNotifier {
  static final TourismRepository instance = TourismRepository._internal();
  TourismRepository._internal() {
    _initFirestoreListener();
    _listenToReviews();
  }

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // User Profile state info
  String userAvatarUrl = '';
  String userBio = 'Exploring the Cattle Trading Capital of the Philippines!';

  List<TourismItem> items = [];
  bool isLoading = true;

  // Reviews are stored in Firestore so every signed-in visitor sees the same data.
  final Map<String, List<Map<String, dynamic>>> _reviews = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _reviewsSubscription;

  void _listenToReviews() {
    _reviewsSubscription?.cancel();
    _reviewsSubscription = _firestore.collectionGroup('reviews')
        .orderBy('createdAt', descending: true)
        .snapshots().listen((snapshot) {
      _reviews.clear();
      for (final doc in snapshot.docs) {
        final spotId = doc.reference.parent.parent?.id;
        if (spotId == null) continue;
        final data = doc.data();
        final created = data['createdAt'];
        data['date'] = created is Timestamp ? _relativeReviewDate(created.toDate()) : 'Recently';
        _reviews.putIfAbsent(spotId, () => []).add(data);
      }
      _recalculateRatings();
      notifyListeners();
    }, onError: (error) {
      debugPrint('Reviews listener error: $error');
    });
  }

  String _relativeReviewDate(DateTime date) {
    final days = DateTime.now().difference(date).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return '1 day ago';
    if (days < 7) return '$days days ago';
    if (days < 30) return '${(days / 7).floor()} weeks ago';
    return '${(days / 30).floor()} months ago';
  }

  void _recalculateRatings() {
    for (final item in items) {
      final reviews = _reviews[item['id']] ?? [];
      if (reviews.isEmpty) continue;
      final total = reviews.fold<int>(0, (sum, review) => sum + ((review['rating'] as num?)?.toInt() ?? 0));
      item['rating'] = double.parse((total / reviews.length).toStringAsFixed(1));
    }
  }

  void _initFirestoreListener() {
    _firestore.collection('tourism_spots').snapshots().listen((snapshot) {
      if (snapshot.docs.isEmpty) {
        // Do not let every visitor attempt to write the initial directory.
        // An administrator must add the official tourism listings.
        items = [];
        isLoading = false;
        notifyListeners();
      } else {
        items = snapshot.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id;
          if (data['gradient'] != null) {
            data['gradient'] = (data['gradient'] as List).map((c) => Color(c as int)).toList();
          } else {
            data['gradient'] = [AppColors.primary, AppColors.primaryLight];
          }
          return data;
        }).toList();
        isLoading = false;
        notifyListeners();
      }
    });
  }

  Future<void> _seedDefaultData() async {
    final defaultSpots = [
      {
        'id': 'p1',
        'title': 'Padre Garcia Livestock Auction Market',
        'mapVerified': true,
        'category': 'Places',
        'desc': 'The premier and largest cattle trading capital hub in the Philippines. Best visited early Friday mornings to witness live traditional livestock trading.',
        'rating': 4.9,
        'cost': 0,
        'hours': '5:00 AM - 2:00 PM (Fridays Peak)',
        'lat': '13.8759888',
        'lng': '121.2152267',
        'badge': 'Must Visit',
        'featured': true,
        'gradient': [0xFF0A3D2E, 0xFF1F7A5E],
      },
      {
        'id': 'p2',
        'title': 'Pick & Go Agritourism Farm',
        'category': 'Places',
        'desc': 'DA & DOT joint agritourism project featuring vibrant sunflower fields, organic greenhouses, and fresh harvest picking.',
        'rating': 4.8,
        'cost': 150,
        'hours': '8:00 AM - 5:00 PM',
        'lat': '13.8717',
        'lng': '121.2277',
        'badge': 'Eco Spot',
        'featured': true,
        'gradient': [0xFF92400E, 0xFFF59E0B],
      },
      {
        'id': 'p3',
        'title': 'Bawi Eco Trail & River Park',
        'mapVerified': true,
        'category': 'Places',
        'desc': 'Scenic nature trail, shaded picnic groves, and crystal-clear natural stream waters perfect for weekend family retreats.',
        'rating': 4.7,
        'cost': 50,
        'hours': '6:00 AM - 6:00 PM',
        'lat': '13.8922421',
        'lng': '121.2332013',
        'badge': 'Nature',
        'featured': false,
        'gradient': [0xFF065F46, 0xFF10B981],
      },
      {
        'id': 'p4',
        'title': 'Padre Garcia Community Park',
        'mapVerified': true,
        'category': 'Places',
        'desc': 'Historic civic center featuring manicured gardens, monuments, and the main stage for community gatherings.',
        'rating': 4.6,
        'cost': 0,
        'hours': 'Open 24 Hours',
        'lat': '13.879633',
        'lng': '121.213798',
        'badge': 'Landmark',
        'featured': false,
        'gradient': [0xFF1E3A8A, 0xFF3B82F6],
      },
      {
        'id': 'p5',
        'title': 'Most Holy Rosary Parish Church',
        'mapVerified': true,
        'category': 'Places',
        'desc': 'Historic local Roman Catholic parish serving as the architectural and spiritual heart of Padre Garcia.',
        'rating': 4.9,
        'cost': 0,
        'hours': '5:30 AM - 7:30 PM',
        'lat': '13.88038',
        'lng': '121.21377',
        'badge': 'Heritage',
        'featured': false,
        'gradient': [0xFF7C2D12, 0xFFEA580C],
      },
      {
        'id': 'p6',
        'title': 'San Roque Chapel & Barangay Grounds',
        'category': 'Places',
        'desc': 'Quiet community chapel surrounded by rolling agricultural terrain and local fruit orchards in Quilo-quilo.',
        'rating': 4.5,
        'cost': 0,
        'hours': '6:00 AM - 6:00 PM',
        'lat': '13.8705',
        'lng': '121.2025',
        'badge': 'Rural View',
        'featured': false,
        'gradient': [0xFF374151, 0xFF6B7280],
      },
      {
        'id': 'p7',
        'title': 'Padre Garcia Municipal Library & Museum',
        'category': 'Places',
        'desc': 'Repository of local history, historical archives, and cultural artifacts detailing the town’s cattle-raising heritage.',
        'rating': 4.7,
        'cost': 0,
        'hours': '8:00 AM - 5:00 PM (Mon-Fri)',
        'lat': '13.8795',
        'lng': '121.2135',
        'badge': 'Culture',
        'featured': false,
        'gradient': [0xFF1F2937, 0xFF4B5563],
      },
      {
        'id': 'p8',
        'title': 'Tangob Riverside Recreation Park',
        'category': 'Places',
        'desc': 'Relaxing riverside spot popular among locals for morning jogs, fishing, and sunset sightseeing in Barangay Tangob.',
        'rating': 4.6,
        'cost': 0,
        'hours': 'Open 24 Hours',
        'lat': '13.8811',
        'lng': '121.2556',
        'badge': 'Scenic',
        'featured': false,
        'gradient': [0xFF047857, 0xFF34D399],
      },
      {
        'id': 'p9',
        'title': 'Maugat Agricultural Nursery',
        'category': 'Places',
        'desc': 'Local plant nursery and ornamental flower farm supplying native trees, seedlings, and landscaping plants in Barangay Maugat.',
        'rating': 4.8,
        'cost': 0,
        'hours': '7:00 AM - 6:00 PM',
        'lat': '13.8677',
        'lng': '121.2898',
        'badge': 'Botanic',
        'featured': false,
        'gradient': [0xFF0D9488, 0xFF2DD4BF],
      },
      {
        'id': 'p10',
        'title': 'Castillo Ancestral Heritage House',
        'category': 'Places',
        'desc': 'Well-preserved Spanish-colonial era ancestral house showcasing classic Batangueno architecture in Barangay Castillo.',
        'rating': 4.9,
        'cost': 50,
        'hours': '9:00 AM - 4:00 PM',
        'lat': '13.8770',
        'lng': '121.2684',
        'badge': 'History',
        'featured': true,
        'gradient': [0xFF78350F, 0xFFB45309],
      },
      {
        'id': 'f1',
        'title': 'Authentic Batangas Lomi House (San Miguel)',
        'category': 'Food',
        'desc': 'Thick fresh egg noodles swimming in rich savory broth, loaded with liver, kikiam, chicharon, and crispy garlic toppings.',
        'rating': 4.9,
        'cost': 120,
        'hours': '8:00 AM - 7:30 PM',
        'lat': '13.8743',
        'lng': '121.2108',
        'badge': 'Top Rated',
        'featured': true,
        'gradient': [0xFF9A3412, 0xFFF97316],
      },
      {
        'id': 'f2',
        'title': 'Padre Garcia Special Halo-Halo',
        'category': 'Food',
        'desc': 'Creamy shaved ice dessert layered with sweetened saba, macapuno, ube halaya, and homemade leche flan along Poblacion.',
        'rating': 4.8,
        'cost': 95,
        'hours': '10:00 AM - 7:00 PM',
        'lat': '13.8776',
        'lng': '121.2137',
        'badge': 'Local Favorite',
        'featured': false,
        'gradient': [0xFF6B21A8, 0xFFA855F7],
      },
      {
        'id': 'f3',
        'title': 'Gotong Batangas Carinderia',
        'category': 'Food',
        'desc': 'Ginger-infused slow-cooked beef tripe soup seasoned with achuete, garlic bits, and calamansi near the Public Market.',
        'rating': 4.8,
        'cost': 110,
        'hours': '6:00 AM - 3:00 PM',
        'lat': '13.8768',
        'lng': '121.2148',
        'badge': 'Specialty',
        'featured': false,
        'gradient': [0xFF854D0E, 0xFFEAB308],
      },
      {
        'id': 'f4',
        'title': 'Garciano Bulalo & Beef Kitchen',
        'category': 'Food',
        'desc': 'Freshly sourced local beef shank and bone marrow simmered for hours with sweet corn and pechay near the Auction Market.',
        'rating': 4.9,
        'cost': 350,
        'hours': '9:00 AM - 9:00 PM',
        'lat': '13.8762',
        'lng': '121.2143',
        'badge': 'Fresh Beef',
        'featured': false,
        'gradient': [0xFF991B1B, 0xFFEF4444],
      },
      {
        'id': 'f5',
        'title': 'Tapang Taal & Kapeng Barako Café',
        'category': 'Food',
        'desc': 'Marinated pork tapa served with garlic fried rice, sunny-side egg, and freshly brewed Batangas Barako coffee along V. Luna St.',
        'rating': 4.7,
        'cost': 145,
        'hours': '6:00 AM - 6:00 PM',
        'lat': '13.8798',
        'lng': '121.2162',
        'badge': 'Breakfast',
        'featured': false,
        'gradient': [0xFF451A03, 0xFF92400E],
      },
      {
        'id': 'f6',
        'title': 'Poblacion Ihaw-Ihaw & Goto Station',
        'category': 'Food',
        'desc': 'Night street food destination offering sizzling pork sisig, grilled chicken inasal, and piping hot goto in Poblacion.',
        'rating': 4.6,
        'cost': 130,
        'hours': '4:00 PM - 12:00 AM',
        'lat': '13.8773',
        'lng': '121.2143',
        'badge': 'Night Food',
        'featured': false,
        'gradient': [0xFFC2410C, 0xFFFB923C],
      },
      {
        'id': 'f7',
        'title': 'Auntie Linda’s Kakanin & Suman House',
        'category': 'Food',
        'desc': 'Traditional homemade rice delicacies including suman sa lihiya, puto maya, sapin-sapin, and cassava cake.',
        'rating': 4.8,
        'cost': 60,
        'hours': '6:00 AM - 5:00 PM',
        'lat': '13.8752',
        'lng': '121.2128',
        'badge': 'Kakanin',
        'featured': false,
        'gradient': [0xFF9333EA, 0xFFC084FC],
      },
      {
        'id': 'f8',
        'title': 'Banca-Banca Fresh Tilapia Grill',
        'category': 'Food',
        'desc': 'Countryside dining spot serving freshly caught grilled tilapia stuffed with tomatoes and onions in Banaba.',
        'rating': 4.7,
        'cost': 220,
        'hours': '10:00 AM - 8:00 PM',
        'lat': '13.8710',
        'lng': '121.2065',
        'badge': 'Seafood',
        'featured': false,
        'gradient': [0xFF0284C7, 0xFF38BDF8],
      },
      {
        'id': 'f9',
        'title': 'Garciano Crispy Pata & Pares House',
        'category': 'Food',
        'desc': 'Golden-brown crispy pork knuckle served with soy-vinegar dipping sauce alongside sweet braised beef pares along National Rd.',
        'rating': 4.8,
        'cost': 380,
        'hours': '11:00 AM - 10:00 PM',
        'lat': '13.8813',
        'lng': '121.2264',
        'badge': 'Crispy Pata',
        'featured': false,
        'gradient': [0xFFB91C1C, 0xFFF87171],
      },
      {
        'id': 'f10',
        'title': 'Poblacion Artisanal Panaderia',
        'category': 'Food',
        'desc': 'Heritage bakery baking freshly stone-oven-baked pandesal, Spanish bread, and cheese rolls every sunrise.',
        'rating': 4.9,
        'cost': 40,
        'hours': '5:00 AM - 7:00 PM',
        'lat': '13.8785',
        'lng': '121.2139',
        'badge': 'Bakery',
        'featured': false,
        'gradient': [0xFF78350F, 0xFFD97706],
      },
      {
        'id': 'a1',
        'title': 'Kabakahan Festival Celebration',
        'category': 'Activities',
        'desc': 'Grand annual festival every December 1 celebrating cattle trading culture with street parades, floats, and community dancing.',
        'rating': 5.0,
        'cost': 0,
        'hours': 'December 1 Annual',
        'lat': '13.8797',
        'lng': '121.2131',
        'badge': 'Festival',
        'featured': true,
        'gradient': [0xFF0F766E, 0xFF14B8A6],
      },
      {
        'id': 'a2',
        'title': 'Rodeo Ala Garciano Arena',
        'category': 'Activities',
        'desc': 'Thrilling competitive rodeo events featuring bull riding, lassoing, and cattle wrestling by skilled handlers.',
        'rating': 4.9,
        'cost': 100,
        'hours': 'Seasonal / Fiesta',
        'lat': '13.8772',
        'lng': '121.2155',
        'badge': 'Thrill',
        'featured': false,
        'gradient': [0xFFB91C1C, 0xFFF59E0B],
      },
      {
        'id': 'a3',
        'title': 'Guided Organic Farm & Sunflower Tour',
        'category': 'Activities',
        'desc': 'Hands-on agricultural tour exploring mushroom cultivation, vegetable plots, and sunflower photo spots at Pick & Go Farm.',
        'rating': 4.7,
        'cost': 200,
        'hours': '8:00 AM - 4:00 PM',
        'lat': '13.8717',
        'lng': '121.2277',
        'badge': 'Guided',
        'featured': false,
        'gradient': [0xFF15803D, 0xFF22C55E],
      },
      {
        'id': 'a4',
        'title': 'Bawi River Trekking & Eco Hike',
        'category': 'Activities',
        'desc': 'Guided morning trek along shaded bamboo trails ending at refreshing natural river pools in Barangay Bawi.',
        'rating': 4.6,
        'cost': 100,
        'hours': '6:00 AM - 3:00 PM',
        'lat': '13.8922421',
        'lng': '121.2332013',
        'badge': 'Adventure',
        'featured': false,
        'gradient': [0xFF0369A1, 0xFF38BDF8],
      },
      {
        'id': 'a5',
        'title': 'Karakol Cultural Street Dance',
        'mapVerified': true,
        'category': 'Activities',
        'desc': 'Vibrant traditional religious and cultural street procession accompanied by lively brass bands from Most Holy Rosary Parish.',
        'rating': 4.9,
        'cost': 0,
        'hours': 'Town Fiesta',
        'lat': '13.88038',
        'lng': '121.21377',
        'badge': 'Culture',
        'featured': false,
        'gradient': [0xFF4338CA, 0xFF6366F1],
      },
      {
        'id': 'a6',
        'title': 'Livestock Auction Morning Observation',
        'mapVerified': true,
        'category': 'Activities',
        'desc': 'Educational walkthrough of the trading pits, grading yards, and livestock exchange procedures.',
        'rating': 4.8,
        'cost': 0,
        'hours': 'Fridays 5:00 AM - 11:00 AM',
        'lat': '13.8759888',
        'lng': '121.2152267',
        'badge': 'Trade Tour',
        'featured': true,
        'gradient': [0xFF0F4C3A, 0xFF22543D],
      },
      {
        'id': 'a7',
        'title': 'Barako Coffee Brewing Workshop',
        'category': 'Activities',
        'desc': 'Hands-on roasting, grinding, and traditional drip brewing workshop focusing on authentic Batangas Barako beans.',
        'rating': 4.8,
        'cost': 250,
        'hours': '9:00 AM - 3:00 PM',
        'lat': '13.8798',
        'lng': '121.2162',
        'badge': 'Workshop',
        'featured': false,
        'gradient': [0xFF78350F, 0xFF92400E],
      },
      {
        'id': 'a8',
        'title': 'Tangob Sunset Riverside Camping',
        'category': 'Activities',
        'desc': 'Overnight stargazing and tent camping setup along the scenic banks of Tangob River.',
        'rating': 4.7,
        'cost': 150,
        'hours': 'Check-in 3:00 PM',
        'lat': '13.8815',
        'lng': '121.2540',
        'badge': 'Camping',
        'featured': false,
        'gradient': [0xFF1E1B4B, 0xFF312E81],
      },
      {
        'id': 'a9',
        'title': 'Traditional Pottery & Clay Molding Class',
        'category': 'Activities',
        'desc': 'Learn traditional earthenware pottery crafting and clay sculpting from local master artisans in Poblacion.',
        'rating': 4.6,
        'cost': 180,
        'hours': '10:00 AM - 4:00 PM',
        'lat': '13.8758',
        'lng': '121.2122',
        'badge': 'Crafts',
        'featured': false,
        'gradient': [0xFF9A3412, 0xFFC2410C],
      },
      {
        'id': 'a10',
        'title': 'Padre Garcia Town Heritage Bike Trail',
        'category': 'Activities',
        'desc': 'Guided cycling tour covering historic municipal landmarks, old ancestral houses, and scenic countryside roads.',
        'rating': 4.9,
        'cost': 80,
        'hours': '6:00 AM - 10:00 AM',
        'lat': '13.8797',
        'lng': '121.2131',
        'badge': 'Cycling',
        'featured': true,
        'gradient': [0xFF047857, 0xFF059669],
      },
    ];

    for (var spot in defaultSpots) {
      final docId = spot['id'] as String;
      final copy = Map<String, dynamic>.from(spot);
      copy.remove('id');
      if (copy['gradient'] != null && copy['gradient'] is List<Color>) {
        copy['gradient'] = (copy['gradient'] as List<Color>).map((c) => c.value).toList();
      }
      final docRef = _firestore.collection('tourism_spots').doc(docId);
      final existingDoc = await docRef.get();
      if (!existingDoc.exists) {
        await docRef.set(copy);
      }
    }
  }

  Future<void> updateProfile({required String newName, required String newBio, required String newAvatar}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Please sign in first.');
    await user.updateDisplayName(newName);
    await _firestore.collection('users').doc(user.uid).set({
      'displayName': newName,
      'bio': newBio,
      'avatarUrl': newAvatar,
      'email': user.email,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    userBio = newBio;
    userAvatarUrl = newAvatar;
    notifyListeners();
  }

  Future<void> loadMyProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await _firestore.collection('users').doc(user.uid).get();
    final data = doc.data();
    if (data == null) return;
    userBio = data['bio'] as String? ?? userBio;
    userAvatarUrl = data['avatarUrl'] as String? ?? '';
    notifyListeners();
  }

  List<Map<String, dynamic>> getReviews(String itemId) => _reviews[itemId] ?? [];

  Future<void> addReview(String itemId, String userName, int stars, String comment) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in to post a review.');
    if (stars < 1 || stars > 5) throw ArgumentError('Rating must be from 1 to 5.');
    await _firestore.collection('tourism_spots').doc(itemId).collection('reviews').add({
      'userId': user.uid,
      'user': userName,
      'rating': stars,
      'comment': comment.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<List<TourismItem>> loadItinerary() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];
    final snap = await _firestore.collection('users').doc(user.uid).collection('itinerary').get();
    return snap.docs.map((doc) => <String, dynamic>{...doc.data(), 'id': doc.id}).toList();
  }

  Future<void> saveItineraryItem(TourismItem item) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Please sign in first.');
    final id = item['id'] as String;
    await _firestore.collection('users').doc(user.uid).collection('itinerary').doc(id).set({
      ...Map<String, dynamic>.from(item)..remove('id'),
      'savedAt': FieldValue.serverTimestamp(),
      'visited': item['visited'] == true,
    }, SetOptions(merge: true));
  }

  Future<void> removeItineraryItem(String id) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Please sign in first.');
    await _firestore.collection('users').doc(user.uid).collection('itinerary').doc(id).delete();
  }

  @override
  void dispose() {
    _reviewsSubscription?.cancel();
    super.dispose();
  }

  // GLOBAL ADD SA FIRESTORE
  Future<void> addItem(TourismItem newItem) async {
    final data = Map<String, dynamic>.from(newItem);
    data.remove('id');
    if (data['gradient'] != null && data['gradient'] is List<Color>) {
      data['gradient'] = (data['gradient'] as List<Color>).map((c) => c.value).toList();
    }
    await _firestore.collection('tourism_spots').add(data);
  }

  // GLOBAL UPDATE SA FIRESTORE
  Future<void> updateItem(String id, TourismItem updatedItem) async {
    final data = Map<String, dynamic>.from(updatedItem);
    data.remove('id');
    if (data['gradient'] != null && data['gradient'] is List<Color>) {
      data['gradient'] = (data['gradient'] as List<Color>).map((c) => c.value).toList();
    }
    await _firestore.collection('tourism_spots').doc(id).update(data);
  }

  // GLOBAL DELETE SA FIRESTORE
  Future<void> deleteItem(String id) async {
    await _firestore.collection('tourism_spots').doc(id).delete();
  }
}

// ==========================================
// REUSABLE ANIMATED TACTILE WRAPPER
// ==========================================
class ScaleTapWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const ScaleTapWrapper({super.key, required this.child, required this.onTap});

  @override
  State<ScaleTapWrapper> createState() => _ScaleTapWrapperState();
}

class _ScaleTapWrapperState extends State<ScaleTapWrapper> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 110));
    _scale = Tween<double>(begin: 1.0, end: 0.95).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

// ==========================================
// CUSTOM HEADER WAVE CLIPPER
// ==========================================
class HeaderWaveClipper extends CustomClipper<ui.Path> {
  @override
  ui.Path getClip(Size size) {
    final path = ui.Path()
      ..lineTo(0, size.height - 26)
      ..quadraticBezierTo(size.width * 0.25, size.height, size.width * 0.55, size.height - 16)
      ..quadraticBezierTo(size.width * 0.85, size.height - 32, size.width, size.height - 10)
      ..lineTo(size.width, 0)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<ui.Path> oldClipper) => false;
}

// ==========================================
// APP ROOT
// ==========================================
class PadreGarciaTourismApp extends StatelessWidget {
  const PadreGarciaTourismApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Padre Garcia Smart Tourism',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: AppColors.primary,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          primary: AppColors.primary,
          secondary: AppColors.accent,
        ),
        scaffoldBackgroundColor: AppColors.bgLight,
        fontFamily: 'Roboto',
      ),
      initialRoute: '/auth',
      routes: {
        '/auth': (context) => const AuthPage(),
        '/dashboard': (context) {
          final email = ModalRoute.of(context)?.settings.arguments as String? ?? 'tourist@gmail.com';
          return DashboardPage(userEmail: email);
        },
      },
    );
  }
}

// ==========================================
// PAGE 1 — ANIMATED AUTHENTICATION SCREEN
// ==========================================
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> with SingleTickerProviderStateMixin {
  bool _isLogin = true;
  bool _agreedToTerms = false;
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscureText = true;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showTermsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Terms & Conditions', style: TextStyle(fontWeight: FontWeight.w900)),
        content: const SingleChildScrollView(
          child: Text(
            'Welcome to Padre Garcia Smart Tourism App!\n\n'
            '1. Account Security: You are responsible for keeping your account email and password secure.\n'
            '2. Accurate Information: When registering, provide a valid email address.\n'
            '3. Code of Conduct: Respect local cultural heritage sites, municipal parks, and fellow travelers while exploring.\n'
            '4. Privacy: Your saved itineraries and preferences are stored securely for a personalized experience.\n\n'
            'By checking the agreement box, you agree to comply with all community tourism regulations.',
            style: TextStyle(height: 1.5, fontSize: 13, color: Colors.black87),
          ),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAuth() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_isLogin && !_agreedToTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please accept the Terms & Conditions to register.'),
          backgroundColor: Colors.orangeAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final email = _emailController.text.trim();
    final pass = _passwordController.text;

    if (_isLogin) {
      bool success = await AuthService.login(email, pass);
      if (success) {
        Navigator.pushReplacementNamed(context, '/dashboard', arguments: email);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid email or password. Please check your credentials.'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      final name = _nameController.text.trim();
      bool success = await AuthService.register(name, email, pass);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account successfully created! Welcome!'),
            backgroundColor: AppColors.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pushReplacementNamed(context, '/dashboard', arguments: email);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Registration failed. This email might already be in use.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.primaryDark, AppColors.primary, AppColors.primaryLight],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (context, _) {
              return Stack(
                children: [
                  Positioned(
                    top: -60 + (_pulseCtrl.value * 25),
                    right: -50,
                    child: Container(
                      width: 250,
                      height: 250,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent.withValues(alpha: 0.14),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: -80 - (_pulseCtrl.value * 20),
                    left: -60,
                    child: Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    ScaleTransition(
                      scale: Tween<double>(begin: 0.95, end: 1.05).animate(
                        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.2),
                              Colors.white.withValues(alpha: 0.05),
                            ],
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.accent, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.accent.withValues(alpha: 0.35),
                              blurRadius: 28,
                              spreadRadius: 3,
                            )
                          ],
                        ),
                        child: const Icon(Icons.agriculture_rounded, size: 54, color: AppColors.accentBright),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'DISCOVER PADRE GARCIA',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.accent.withValues(alpha: 0.45)),
                      ),
                      child: const Text(
                        'Cattle Trading Capital of the Philippines',
                        style: TextStyle(fontSize: 12, color: AppColors.accentSoft, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 28),

                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.32),
                            blurRadius: 32,
                            offset: const Offset(0, 14),
                          ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: AppColors.bgLight,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => setState(() => _isLogin = true),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 220),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        decoration: BoxDecoration(
                                          color: _isLogin ? AppColors.primary : Colors.transparent,
                                          borderRadius: BorderRadius.circular(12),
                                          boxShadow: _isLogin
                                              ? [const BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))]
                                              : [],
                                        ),
                                        child: Text(
                                          'Sign In',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: _isLogin ? Colors.white : AppColors.textMuted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => setState(() => _isLogin = false),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 220),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        decoration: BoxDecoration(
                                          color: !_isLogin ? AppColors.primary : Colors.transparent,
                                          borderRadius: BorderRadius.circular(12),
                                          boxShadow: !_isLogin
                                              ? [const BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))]
                                              : [],
                                        ),
                                        child: Text(
                                          'Create Account',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: !_isLogin ? Colors.white : AppColors.textMuted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),

                            AnimatedSize(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeInOut,
                              child: !_isLogin
                                  ? Padding(
                                      padding: const EdgeInsets.only(bottom: 14),
                                      child: TextFormField(
                                        controller: _nameController,
                                        decoration: InputDecoration(
                                          labelText: 'Full Name',
                                          prefixIcon: const Icon(Icons.person_outline, color: AppColors.primary),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(14),
                                            borderSide: BorderSide.none,
                                          ),
                                          filled: true,
                                          fillColor: AppColors.bgLight,
                                        ),
                                        validator: (val) => (val == null || val.trim().isEmpty) ? 'Enter your name' : null,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),

                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                labelText: 'Email',
                                prefixIcon: const Icon(Icons.email_outlined, color: AppColors.primary),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: AppColors.bgLight,
                              ),
                              validator: (val) {
                                if (val == null || val.trim().isEmpty) return 'Enter your email';
                                if (!val.contains('@') || !val.contains('.')) return 'Enter a valid email address';
                                return null;
                              },
                            ),
                            const SizedBox(height: 14),

                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscureText,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline, color: AppColors.primary),
                                suffixIcon: IconButton(
                                  icon: Icon(_obscureText ? Icons.visibility_off : Icons.visibility),
                                  onPressed: () => setState(() => _obscureText = !_obscureText),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: AppColors.bgLight,
                              ),
                              validator: (val) => (val == null || val.length < 6) ? 'Minimum 6 characters' : null,
                            ),

                            AnimatedSize(
                              duration: const Duration(milliseconds: 250),
                              child: !_isLogin
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Row(
                                        children: [
                                          Checkbox(
                                            value: _agreedToTerms,
                                            activeColor: AppColors.primary,
                                            onChanged: (val) => setState(() => _agreedToTerms = val ?? false),
                                          ),
                                          Expanded(
                                            child: GestureDetector(
                                              onTap: _showTermsDialog,
                                              child: const Text(
                                                'I agree to the Terms & Conditions',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: AppColors.primary,
                                                  fontWeight: FontWeight.bold,
                                                  decoration: TextDecoration.underline,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),

                            const SizedBox(height: 22),

                            ScaleTapWrapper(
                              onTap: _handleAuth,
                              child: Container(
                                height: 54,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [AppColors.accent, AppColors.accentBright],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.accent.withValues(alpha: 0.45),
                                      blurRadius: 14,
                                      offset: const Offset(0, 6),
                                    )
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _isLogin ? 'Sign In & Explore' : 'Register Account',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                    color: AppColors.primaryDark,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// PAGE 2 — MAIN DASHBOARD SHELL
// ==========================================
class DashboardPage extends StatefulWidget {
  final String userEmail;
  const DashboardPage({super.key, required this.userEmail});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _currentIndex = 0;
  final List<TourismItem> _itinerary = [];
  final Set<String> _visitedIds = {};
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _loadAccountData();
  }

  Future<void> _loadAccountData() async {
    await TourismRepository.instance.loadMyProfile();
    final savedTrip = await TourismRepository.instance.loadItinerary();
    if (mounted) {
      setState(() {
        _itinerary
          ..clear()
          ..addAll(savedTrip);
        _visitedIds
          ..clear()
          ..addAll(savedTrip.where((item) => item['visited'] == true).map((item) => item['id'] as String));
      });
    }
    final admin = await AuthService.isAdmin(widget.userEmail);
    if (mounted) setState(() => _isAdmin = admin);

    // Seed the built-in directory once from an authenticated administrator.
    // Existing documents (including admin-added listings and edits) are preserved.
    if (admin) {
      try {
        await TourismRepository.instance._seedDefaultData();
      } catch (e) {
        debugPrint('Default tourism data seed failed: $e');
      }
    }
  }

  Future<void> _toggleItinerary(TourismItem item) async {
    final id = item['id'] as String;
    final exists = _itinerary.any((e) => e['id'] == id);
    try {
      if (exists) {
        await TourismRepository.instance.removeItineraryItem(id);
        if (!mounted) return;
        setState(() {
          _itinerary.removeWhere((e) => e['id'] == id);
          _visitedIds.remove(id);
        });
        _showToast('Removed "${item['title']}" from My Trip', Colors.grey.shade800);
      } else {
        final saved = Map<String, dynamic>.from(item)..['visited'] = false;
        await TourismRepository.instance.saveItineraryItem(saved);
        if (!mounted) return;
        setState(() => _itinerary.add(saved));
        _showToast('Added "${item['title']}" to My Trip!', AppColors.primary);
      }
    } catch (e) {
      if (mounted) _showToast('Could not sync your trip. Check your internet connection.', Colors.red);
    }
  }

  Future<void> _toggleVisited(String id) async {
    final nowVisited = !_visitedIds.contains(id);
    final index = _itinerary.indexWhere((item) => item['id'] == id);
    if (index < 0) return;
    final updated = Map<String, dynamic>.from(_itinerary[index])..['visited'] = nowVisited;
    try {
      await TourismRepository.instance.saveItineraryItem(updated);
      if (!mounted) return;
      setState(() {
        _itinerary[index] = updated;
        if (nowVisited) { _visitedIds.add(id); } else { _visitedIds.remove(id); }
      });
    } catch (e) {
      if (mounted) _showToast('Could not sync visit status.', Colors.red);
    }
  }

  void _showToast(String msg, Color bg) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 2),
      ),
    );
  }


  Widget _buildBottomNavItem({
    required int index,
    required String label,
    required IconData icon,
    required IconData selectedIcon,
    bool showTripBadge = false,
  }) {
    final selected = _currentIndex == index;

    return SizedBox(
      width: 86,
      height: 70,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _currentIndex = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 48,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: showTripBadge
                      ? Badge(
                          isLabelVisible: _itinerary.isNotEmpty,
                          backgroundColor: AppColors.accent,
                          textColor: AppColors.primaryDark,
                          label: Text(
                            '${_itinerary.length}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          child: Icon(
                            selected ? selectedIcon : icon,
                            size: 22,
                            color: selected ? AppColors.primary : AppColors.textMuted,
                          ),
                        )
                      : Icon(
                          selected ? selectedIcon : icon,
                          size: 22,
                          color: selected ? AppColors.primary : AppColors.textMuted,
                        ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 25,
                  child: Center(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.05,
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected ? AppColors.primary : AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userName = AuthService.getName(widget.userEmail);
    final isAdmin = _isAdmin;

    return AnimatedBuilder(
      animation: TourismRepository.instance,
      builder: (context, _) {
        final pages = [
          DiscoverTab(
            userName: userName,
            isAdmin: isAdmin,
            itinerary: _itinerary,
            onToggleItinerary: _toggleItinerary,
          ),
          InteractiveMapTab(
            userName: userName,
            itinerary: _itinerary,
            onToggleItinerary: _toggleItinerary,
          ),
          MyTripTab(
            itinerary: _itinerary,
            visitedIds: _visitedIds,
            onToggleVisited: _toggleVisited,
            onRemove: _toggleItinerary,
          ),
          const TravelGuideTab(),
          const AIGuideTab(),
          ProfileTab(userEmail: widget.userEmail),
          if (isAdmin) const AdminManagerTab(),
        ];

        return Scaffold(
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutCubic,
            child: pages[_currentIndex],
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Container(
              height: 78,
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 18,
                    offset: Offset(0, -3),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildBottomNavItem(
                      index: 0,
                      label: 'Discover',
                      icon: Icons.explore_outlined,
                      selectedIcon: Icons.explore,
                    ),
                    _buildBottomNavItem(
                      index: 1,
                      label: 'Live Map',
                      icon: Icons.map_outlined,
                      selectedIcon: Icons.map,
                    ),
                    _buildBottomNavItem(
                      index: 2,
                      label: 'My Trip',
                      icon: Icons.bookmark_border,
                      selectedIcon: Icons.bookmark,
                      showTripBadge: true,
                    ),
                    _buildBottomNavItem(
                      index: 3,
                      label: 'Guide & Fare',
                      icon: Icons.flight_takeoff_outlined,
                      selectedIcon: Icons.flight_takeoff,
                    ),
                    _buildBottomNavItem(
                      index: 4,
                      label: 'cAIttle',
                      icon: Icons.auto_awesome_outlined,
                      selectedIcon: Icons.auto_awesome,
                    ),
                    _buildBottomNavItem(
                      index: 5,
                      label: 'Profile',
                      icon: Icons.person_outline_rounded,
                      selectedIcon: Icons.person_rounded,
                    ),
                    if (isAdmin)
                      _buildBottomNavItem(
                        index: 6,
                        label: 'Admin',
                        icon: Icons.admin_panel_settings_outlined,
                        selectedIcon: Icons.admin_panel_settings,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ==========================================
// TAB 1 — RICH EDITORIAL DISCOVER & SPOTLIGHT HUB
// ==========================================
class DiscoverTab extends StatefulWidget {
  final String userName;
  final bool isAdmin;
  final List<TourismItem> itinerary;
  final Function(TourismItem) onToggleItinerary;

  const DiscoverTab({
    super.key,
    required this.userName,
    required this.isAdmin,
    required this.itinerary,
    required this.onToggleItinerary,
  });

  @override
  State<DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<DiscoverTab> with SingleTickerProviderStateMixin {
  String _selectedCategory = 'All';
  String _searchText = '';
  late AnimationController _headerFloatCtrl;
  late PageController _carouselCtrl;
  double _currentPage = 0.0;

  @override
  void initState() {
    super.initState();
    _headerFloatCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    _carouselCtrl = PageController(viewportFraction: 0.82);
    _carouselCtrl.addListener(() {
      setState(() {
        _currentPage = _carouselCtrl.page ?? 0.0;
      });
    });
  }

  @override
  void dispose() {
    _headerFloatCtrl.dispose();
    _carouselCtrl.dispose();
    super.dispose();
  }

  IconData _getCategoryIcon(String cat) {
    if (cat == 'Food') return Icons.restaurant_rounded;
    if (cat == 'Activities') return Icons.local_activity_rounded;
    return Icons.place_rounded;
  }

  void _openItemModal(TourismItem item) {
    final isSaved = widget.itinerary.any((e) => e['id'] == item['id']);
    final gradColors = (item['gradient'] as List<Color>?) ?? [AppColors.primary, AppColors.primaryLight];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 165,
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradColors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -20,
                      bottom: -20,
                      child: Icon(
                        _getCategoryIcon(item['category'] as String),
                        size: 150,
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 44,
                              height: 5,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${item['category']} • ${item['badge']}',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '★ ${item['rating']}',
                                  style: const TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.w900, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['title'] as String,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textDark),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: AppColors.bgLight, borderRadius: BorderRadius.circular(10)),
                          child: Row(
                            children: [
                              const Icon(Icons.access_time_rounded, size: 15, color: AppColors.primary),
                              const SizedBox(width: 6),
                              Text(item['hours'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(10)),
                          child: Text(
                            (item['cost'] as num) == 0 ? 'FREE ENTRY' : 'Est. ₱${item['cost']}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFFB45309)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      item['desc'] as String,
                      style: const TextStyle(fontSize: 15, color: Colors.black87, height: 1.55),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isSaved ? Colors.red.shade600 : AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 3,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        icon: Icon(isSaved ? Icons.bookmark_remove : Icons.bookmark_add),
                        label: Text(
                          isSaved ? 'Remove from My Trip' : 'Add to My Trip Itinerary',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onToggleItinerary(item);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final allItems = TourismRepository.instance.items;
    final featuredItems = allItems.where((e) => e['featured'] == true).toList();
    final filtered = allItems.where((item) {
      final matchesCat = _selectedCategory == 'All' || item['category'] == _selectedCategory;
      final q = _searchText.toLowerCase();
      final matchesSearch = (item['title'] as String).toLowerCase().contains(q) ||
          (item['desc'] as String).toLowerCase().contains(q);
      return matchesCat && matchesSearch;
    }).toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ClipPath(
            clipper: HeaderWaveClipper(),
            child: Container(
              height: 275,
              padding: const EdgeInsets.fromLTRB(20, 44, 20, 32),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primaryDark, AppColors.primary, AppColors.primaryLight],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _headerFloatCtrl,
                    builder: (context, _) {
                      return Stack(
                        children: [
                          Positioned(
                            right: -25 + (_headerFloatCtrl.value * 14),
                            top: -15 + (_headerFloatCtrl.value * 10),
                            child: Container(
                              width: 170,
                              height: 170,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: RadialGradient(
                                  colors: [
                                    AppColors.accent.withValues(alpha: 0.22),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 10,
                            bottom: 12 + (_headerFloatCtrl.value * 6),
                            child: Icon(
                              Icons.agriculture_rounded,
                              size: 105,
                              color: AppColors.accent.withValues(alpha: 0.14),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                            decoration: BoxDecoration(
                              color: widget.isAdmin ? AppColors.accent : Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: widget.isAdmin
                                  ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.4), blurRadius: 8)]
                                  : [],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  widget.isAdmin ? Icons.verified_user_rounded : Icons.explore_rounded,
                                  size: 13,
                                  color: widget.isAdmin ? AppColors.primaryDark : Colors.white,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  widget.isAdmin ? 'ADMINISTRATOR' : 'TOURIST PASS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                    color: widget.isAdmin ? AppColors.primaryDark : Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.wb_sunny_rounded, size: 12, color: AppColors.accentBright),
                                SizedBox(width: 4),
                                Text(
                                  '29°C • Batangas',
                                  style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.logout_rounded, color: Colors.white, size: 19),
                              tooltip: 'Sign Out',
                              onPressed: () => Navigator.pushReplacementNamed(context, '/auth'),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        'Mabuhay, ${widget.userName}!',
                        style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: Colors.white),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Explore Batangas’ Cattle Trading Capital',
                        style: TextStyle(fontSize: 13, color: Colors.white70),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildHeroStat('${allItems.length}+', 'Destinations'),
                            Container(width: 1, height: 22, color: Colors.white24),
                            _buildHeroStat('4.9 ★', 'Top Rated'),
                            Container(width: 1, height: 22, color: Colors.white24),
                            _buildHeroStat('Dec 1', 'Kabakahan'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 5)),
                    ],
                  ),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search spots, lomi, festivals...',
                      hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 14),
                      prefixIcon: Icon(Icons.search_rounded, color: AppColors.primary),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 15),
                    ),
                    onChanged: (val) => setState(() => _searchText = val),
                  ),
                ),
              ),
              if (_searchText.isEmpty && _selectedCategory == 'All') ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 10, 18, 10),
                  child: Row(
                    children: [
                      Icon(Icons.local_fire_department_rounded, color: AppColors.accent, size: 20),
                      SizedBox(width: 6),
                      Text(
                        'Featured Highlights',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.textDark),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 170,
                  child: PageView.builder(
                    controller: _carouselCtrl,
                    itemCount: featuredItems.length,
                    itemBuilder: (context, idx) {
                      final feat = featuredItems[idx];
                      final gradColors = (feat['gradient'] as List<Color>?) ?? [AppColors.primary, AppColors.primaryLight];
                      final diff = (idx - _currentPage).abs();
                      final scale = (1.0 - (diff * 0.07)).clamp(0.9, 1.0);

                      return Transform.scale(
                        scale: scale,
                        child: ScaleTapWrapper(
                          onTap: () => _openItemModal(feat),
                          child: Container(
                            margin: const EdgeInsets.only(right: 10, bottom: 8),
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: gradColors,
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(26),
                              boxShadow: [
                                BoxShadow(
                                  color: gradColors.first.withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                Positioned(
                                  right: -12,
                                  bottom: -12,
                                  child: Icon(
                                    _getCategoryIcon(feat['category'] as String),
                                    size: 96,
                                    color: Colors.white.withValues(alpha: 0.18),
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: 0.24),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            feat['badge'] as String,
                                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          '★ ${feat['rating']}',
                                          style: const TextStyle(color: AppColors.accentBright, fontWeight: FontWeight.w900, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                    const Spacer(),
                                    Text(
                                      feat['title'] as String,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w900,
                                        height: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      (feat['cost'] as num) == 0 ? 'Free Admission' : 'Starts at ₱${feat['cost']}',
                                      style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: ['All', 'Places', 'Food', 'Activities'].map((cat) {
                      final selected = _selectedCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => setState(() => _selectedCategory = cat),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            decoration: BoxDecoration(
                              color: selected ? AppColors.primary : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: selected
                                  ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.32), blurRadius: 8, offset: const Offset(0, 3))]
                                  : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4)],
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                color: selected ? Colors.white : AppColors.textDark,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = filtered[index];
                final isSaved = widget.itinerary.any((e) => e['id'] == item['id']);
                final cat = item['category'] as String;
                final gradColors = (item['gradient'] as List<Color>?) ?? [AppColors.primary, AppColors.primaryLight];

                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: Duration(milliseconds: 280 + (index * 45).clamp(0, 350)),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) {
                    return Transform.translate(
                      offset: Offset(0, 24 * (1 - value)),
                      child: Opacity(opacity: value, child: child),
                    );
                  },
                  child: ScaleTapWrapper(
                    onTap: () => _openItemModal(item),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: Colors.grey.shade100),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: gradColors,
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                  color: gradColors.first.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Icon(_getCategoryIcon(cat), color: Colors.white, size: 32),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppColors.accentSoft,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        item['badge'] as String,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFFB45309),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '★ ${item['rating']}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.accent),
                                    ),
                                    const Spacer(),
                                    Text(
                                      (item['cost'] as num) == 0 ? 'FREE' : '₱${item['cost']}',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.primaryLight),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  item['title'] as String,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: AppColors.textDark),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  item['desc'] as String,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.35),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                              child: Icon(
                                isSaved ? Icons.bookmark_added_rounded : Icons.bookmark_add_outlined,
                                key: ValueKey(isSaved),
                                color: isSaved ? AppColors.primary : Colors.grey.shade400,
                                size: 26,
                              ),
                            ),
                            onPressed: () => widget.onToggleItinerary(item),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              childCount: filtered.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroStat(String value, String label) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: AppColors.accentBright, fontWeight: FontWeight.w900, fontSize: 14)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ==========================================
// TAB 2 — INTERACTIVE MAP
// ==========================================
class InteractiveMapTab extends StatefulWidget {
  final String userName;
  final List<TourismItem> itinerary;
  final Function(TourismItem) onToggleItinerary;

  const InteractiveMapTab({
    super.key,
    required this.userName,
    required this.itinerary,
    required this.onToggleItinerary,
  });

  @override
  State<InteractiveMapTab> createState() => _InteractiveMapTabState();
}

class _InteractiveMapTabState extends State<InteractiveMapTab> {
  String _mapCategory = 'All';
  String _mapSearch = '';
  TourismItem? _selectedPin;
  bool _isPanelOpen = true;
  final MapController _mapController = MapController();

  static final LatLng _padreGarciaCenter = LatLng(13.8785, 121.2140);
  LatLng? _currentUserLocation;

  @override
  void initState() {
    super.initState();
    final items = TourismRepository.instance.items;
    if (items.isNotEmpty) {
      _selectedPin = items.first;
    }
  }

  Future<void> _getCurrentUserLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please turn on Location Services on your device.')),
          );
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Location permission is needed. Allow it in your app settings.'),
            ),
          );
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;
      final userLocation = LatLng(position.latitude, position.longitude);
      setState(() => _currentUserLocation = userLocation);
      _mapController.move(userLocation, 16.0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not get your location. Check permissions and try again.')),
        );
      }
      debugPrint('Current location error: $e');
    }
  }

  void _showWriteReviewDialog(TourismItem item) {
    int selectedStars = 5;
    final commentCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['title'] as String,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Posting publicly as ${widget.userName}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (idx) {
                        final starNum = idx + 1;
                        return IconButton(
                          iconSize: 36,
                          onPressed: () => setDialogState(() => selectedStars = starNum),
                          icon: Icon(
                            starNum <= selectedStars ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: AppColors.accent,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: commentCtrl,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Share details of your own experience at this place...',
                        filled: true,
                        fillColor: AppColors.bgLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    final text = commentCtrl.text.trim();
                    if (text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please write a short comment before posting.')),
                      );
                      return;
                    }
                    TourismRepository.instance.addReview(
                      item['id'] as String,
                      widget.userName,
                      selectedStars,
                      text,
                    );
                    Navigator.pop(context);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Review & rating posted!'),
                        backgroundColor: AppColors.primary,
                      ),
                    );
                  },
                  child: const Text('Post Review', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildStarRow(double rating, {double size = 16}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i + 1 <= rating.floor()) {
          return Icon(Icons.star_rounded, color: AppColors.accent, size: size);
        } else if (i < rating) {
          return Icon(Icons.star_half_rounded, color: AppColors.accent, size: size);
        }
        return Icon(Icons.star_outline_rounded, color: Colors.grey.shade300, size: size);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allItems = TourismRepository.instance.items;
    final visiblePins = allItems.where((loc) {
      // Show every listing with real, valid coordinates. Do not require
      // mapVerified: admin-created listings are immediately eligible too.
      final lat = double.tryParse(loc['lat']?.toString() ?? '');
      final lng = double.tryParse(loc['lng']?.toString() ?? '');
      final hasValidCoordinates = lat != null &&
          lng != null &&
          lat.isFinite &&
          lng.isFinite &&
          lat >= -90 && lat <= 90 &&
          lng >= -180 && lng <= 180;
      if (!hasValidCoordinates) return false;

      final catMatch = _mapCategory == 'All' || loc['category'] == _mapCategory;
      final qMatch = (loc['title']?.toString() ?? '')
          .toLowerCase()
          .contains(_mapSearch.toLowerCase());
      return catMatch && qMatch;
    }).toList();

    final activePin = _selectedPin ?? (visiblePins.isNotEmpty ? visiblePins.first : (allItems.isNotEmpty ? allItems.first : {
      'id': 'default',
      'title': 'Padre Garcia Center',
      'category': 'Places',
      'desc': 'Cattle Trading Capital',
      'rating': 5.0,
      'cost': 0,
      'hours': '24/7',
      'lat': '13.8785',
      'lng': '121.2140',
      'badge': 'Hub',
      'gradient': [Colors.green, Colors.teal]
    }));

    final activeLat = double.tryParse(activePin['lat'].toString()) ?? 13.8785;
    final activeLng = double.tryParse(activePin['lng'].toString()) ?? 121.2140;
    final activeLatLng = LatLng(activeLat, activeLng);

    final isSaved = widget.itinerary.any((e) => e['id'] == activePin['id']);
    final reviews = TourismRepository.instance.getReviews(activePin['id'] as String);
    final gradColors = (activePin['gradient'] as List<Color>?) ?? [AppColors.primary, AppColors.primaryLight];

    final Map<int, int> starCounts = {5: 0, 4: 0, 3: 0, 2: 0, 1: 0};
    for (var r in reviews) {
      final s = (r['rating'] as int).clamp(1, 5);
      starCounts[s] = (starCounts[s] ?? 0) + 1;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final panelWidth = screenWidth > 650 ? 380.0 : screenWidth * 0.84;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _padreGarciaCenter,
              initialZoom: 14.0,
              minZoom: 10.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.padregarcia.tourism',
              ),
              MarkerLayer(
                markers: [
                  ...visiblePins.map((loc) {
                    final isSelected = activePin['id'] == loc['id'];
                    final lLat = double.tryParse(loc['lat'].toString()) ?? 13.8785;
                    final lLng = double.tryParse(loc['lng'].toString()) ?? 121.2140;

                    Color pinColor = Colors.red.shade600;
                    if (loc['category'] == 'Food') pinColor = Colors.orange.shade700;
                    if (loc['category'] == 'Activities') pinColor = Colors.teal.shade700;

                    return Marker(
                      point: LatLng(lLat, lLng),
                      width: 140,
                      height: 75,
                      alignment: Alignment.bottomCenter,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedPin = loc;
                            _isPanelOpen = true;
                          });
                          _mapController.move(LatLng(lLat, lLng), 16.0);
                        },
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSelected)
                              Container(
                                margin: const EdgeInsets.only(bottom: 2),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                                ),
                                child: Text(
                                  loc['title'] as String,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                                ),
                              ),
                            Icon(
                              Icons.location_pin,
                              color: isSelected ? AppColors.accent : pinColor,
                              size: isSelected ? 44 : 36,
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  if (_currentUserLocation != null)
                    Marker(
                      point: _currentUserLocation!,
                      width: 50,
                      height: 50,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue.shade600,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                        ),
                        child: const Icon(Icons.person, color: Colors.white, size: 24),
                      ),
                    ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(
                left: (_isPanelOpen && screenWidth > 650) ? panelWidth + 16 : 16,
                top: 12,
                right: 16,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ['All', 'Places', 'Food', 'Activities'].map((cat) {
                    final active = _mapCategory == cat;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () => setState(() => _mapCategory = cat),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: active ? AppColors.primaryDark : Colors.white.withValues(alpha: 0.96),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
                          ),
                          child: Text(
                            cat,
                            style: TextStyle(
                              color: active ? AppColors.accentBright : AppColors.textDark,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: _isPanelOpen ? 0 : -panelWidth,
            top: 0,
            bottom: 0,
            width: panelWidth + 28,
            child: Row(
              children: [
                Container(
                  width: panelWidth,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(3, 0))],
                  ),
                  child: SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppColors.bgLight,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.search_rounded, color: AppColors.primary, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    decoration: const InputDecoration(
                                      hintText: 'Search Padre Garcia spots...',
                                      hintStyle: TextStyle(fontSize: 13),
                                      border: InputBorder.none,
                                    ),
                                    onChanged: (val) => setState(() => _mapSearch = val),
                                  ),
                                ),
                                if (_mapSearch.isNotEmpty)
                                  GestureDetector(
                                    onTap: () => setState(() => _mapSearch = ''),
                                    child: const Icon(Icons.close_rounded, size: 18, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  height: 120,
                                  width: double.infinity,
                                  margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(colors: gradColors),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.black26,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '${activePin['category']} • ${activePin['badge']}',
                                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        activePin['title'] as String,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: AppColors.primary,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          ),
                                          icon: const Icon(Icons.near_me_rounded, size: 16),
                                          label: const Text('Focus Pin', style: TextStyle(fontSize: 12)),
                                          onPressed: () => _mapController.move(activeLatLng, 17.0),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: AppColors.primary,
                                            side: const BorderSide(color: AppColors.primary),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          ),
                                          icon: Icon(isSaved ? Icons.bookmark_added : Icons.bookmark_border, size: 16),
                                          label: Text(isSaved ? 'Saved' : 'Save', style: const TextStyle(fontSize: 12)),
                                          onPressed: () => widget.onToggleItinerary(activePin),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        activePin['desc'] as String,
                                        style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.4),
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          const Icon(Icons.access_time_rounded, size: 14, color: AppColors.primary),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              activePin['hours'] as String,
                                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 24),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Review summary',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textDark),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            flex: 3,
                                            child: Column(
                                              children: [5, 4, 3, 2, 1].map((star) {
                                                final count = starCounts[star] ?? 0;
                                                final ratio = reviews.isEmpty ? 0.0 : count / reviews.length;
                                                return Padding(
                                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                                  child: Row(
                                                    children: [
                                                      Text('$star', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                                      const SizedBox(width: 8),
                                                      Expanded(
                                                        child: ClipRRect(
                                                          borderRadius: BorderRadius.circular(4),
                                                          child: LinearProgressIndicator(
                                                            value: ratio,
                                                            minHeight: 7,
                                                            backgroundColor: Colors.grey.shade200,
                                                            color: AppColors.accent,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Column(
                                            children: [
                                              Text(
                                                '${activePin['rating']}',
                                                style: const TextStyle(
                                                  fontSize: 38,
                                                  fontWeight: FontWeight.w900,
                                                  height: 1.0,
                                                  color: AppColors.textDark,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              _buildStarRow((activePin['rating'] as num).toDouble(), size: 15),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${reviews.length} ${reviews.length == 1 ? 'review' : 'reviews'}',
                                                style: const TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.w600),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 14),
                                      Center(
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            backgroundColor: AppColors.primary.withValues(alpha: 0.08),
                                            foregroundColor: AppColors.primary,
                                            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          ),
                                          icon: const Icon(Icons.rate_review_outlined, size: 18),
                                          label: const Text('Write a review', style: TextStyle(fontWeight: FontWeight.bold)),
                                          onPressed: () => _showWriteReviewDialog(activePin),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 24),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Reviews',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textDark),
                                      ),
                                      const SizedBox(height: 10),
                                      if (reviews.isEmpty)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(vertical: 16),
                                          child: Text(
                                            'No reviews yet. Be the first to rate and comment on this spot!',
                                            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                                          ),
                                        )
                                      else
                                        ...reviews.map((rev) {
                                          final userInitial = (rev['user'] as String).isNotEmpty
                                              ? (rev['user'] as String)[0].toUpperCase()
                                              : 'T';
                                          return Container(
                                            margin: const EdgeInsets.only(bottom: 14),
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: AppColors.bgLight.withValues(alpha: 0.6),
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    CircleAvatar(
                                                      radius: 16,
                                                      backgroundColor: AppColors.primary,
                                                      child: Text(
                                                        userInitial,
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontWeight: FontWeight.bold,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          Text(
                                                            rev['user'] as String,
                                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                                          ),
                                                          const Text(
                                                            'Local Explorer',
                                                            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 6),
                                                Row(
                                                  children: [
                                                    _buildStarRow((rev['rating'] as int).toDouble(), size: 14),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      rev['date'] as String,
                                                      style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  rev['comment'] as String,
                                                  style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.35),
                                                ),
                                              ],
                                            ),
                                          );
                                        }),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _isPanelOpen = !_isPanelOpen),
                  child: Container(
                    width: 26,
                    height: 56,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.horizontal(right: Radius.circular(10)),
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(2, 0))],
                    ),
                    child: Icon(
                      _isPanelOpen ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                      color: AppColors.textDark,
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 16,
            bottom: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'resetMapBtn',
                  onPressed: () => _mapController.move(_padreGarciaCenter, 14.0),
                  backgroundColor: Colors.white,
                  child: const Icon(Icons.refresh_rounded, color: AppColors.primaryDark),
                ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  heroTag: 'gpsLocationBtn',
                  onPressed: _getCurrentUserLocation,
                  backgroundColor: AppColors.primary,
                  child: const Icon(Icons.my_location, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// TAB 3 — MY TRIP PLANNER
// ==========================================
class MyTripTab extends StatelessWidget {
  final List<TourismItem> itinerary;
  final Set<String> visitedIds;
  final Function(String) onToggleVisited;
  final Function(TourismItem) onRemove;

  const MyTripTab({
    super.key,
    required this.itinerary,
    required this.visitedIds,
    required this.onToggleVisited,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    int totalBudget = 0;
    for (var item in itinerary) {
      totalBudget += (item['cost'] as num).toInt();
    }

    final double progress = itinerary.isEmpty ? 0.0 : (visitedIds.length / itinerary.length);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Trip Planner', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        backgroundColor: AppColors.primaryDark,
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primaryDark, AppColors.primary, AppColors.primaryLight],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(26),
              boxShadow: [
                BoxShadow(color: AppColors.primary.withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 6)),
              ],
            ),
            child: Row(
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: progress),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  builder: (context, val, _) {
                    return SizedBox(
                      width: 68,
                      height: 68,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: val,
                            strokeWidth: 7,
                            backgroundColor: Colors.white.withValues(alpha: 0.15),
                            color: AppColors.accentBright,
                          ),
                          Text(
                            '${(val * 100).round()}%',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 14),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStat('${itinerary.length}', 'Stops'),
                      Container(width: 1, height: 34, color: Colors.white24),
                      _buildStat('${visitedIds.length}/${itinerary.length}', 'Visited'),
                      Container(width: 1, height: 34, color: Colors.white24),
                      _buildStat('₱$totalBudget', 'Budget'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: itinerary.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.explore_outlined, size: 64, color: AppColors.primary),
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            'Your Itinerary is Empty',
                            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: AppColors.textDark),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Tap the bookmark icon on any attraction, lomi house, or festival to build your custom Padre Garcia trip.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textMuted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: itinerary.length,
                    itemBuilder: (context, index) {
                      final item = itinerary[index];
                      final id = item['id'] as String;
                      final done = visitedIds.contains(id);

                      return Dismissible(
                        key: ValueKey(id),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => onRemove(item),
                        background: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.only(right: 20),
                          alignment: Alignment.centerRight,
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Icon(Icons.delete_rounded, color: Colors.white),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: done ? Colors.white.withValues(alpha: 0.7) : Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            boxShadow: [
                              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3)),
                            ],
                          ),
                          child: ListTile(
                            leading: Checkbox(
                              value: done,
                              activeColor: AppColors.primary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              onChanged: (_) => onToggleVisited(id),
                            ),
                            title: Text(
                              item['title'] as String,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                decoration: done ? TextDecoration.lineThrough : null,
                                color: done ? AppColors.textMuted : AppColors.textDark,
                              ),
                            ),
                            subtitle: Text(
                              '${item['category']} • ${(item['cost'] as num) == 0 ? 'Free' : 'Est. ₱${item['cost']}'}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                              onPressed: () => onRemove(item),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.accentBright),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ==========================================
// TRAVEL GUIDE & FARE ESTIMATOR TAB
// ==========================================
class TravelGuideTab extends StatefulWidget {
  const TravelGuideTab({super.key});

  @override
  State<TravelGuideTab> createState() => _TravelGuideTabState();
}

class _TravelGuideTabState extends State<TravelGuideTab> {
  String _origin = 'Lipa City';
  String _transportMode = 'Tricycle / Commute';
  TourismItem? _selectedDestination;

  final List<String> _origins = [
    'Lipa City',
    'San Jose Batangas',
    'Batangas City',
    'Rosario Batangas',
    'Manila / PITX',
  ];

  final List<String> _transportModes = [
    'Tricycle / Commute',
    'Private Car / Taxi',
    'Bus & Jeepney Combo',
  ];

  @override
  void initState() {
    super.initState();
    final items = TourismRepository.instance.items;
    if (items.isNotEmpty) {
      _selectedDestination = items.first;
    }
  }

  Map<String, dynamic> _calculateEstimate() {
    double baseDistanceKm = 12.0;
    if (_origin == 'Lipa City') baseDistanceKm = 8.5;
    if (_origin == 'San Jose Batangas') baseDistanceKm = 10.0;
    if (_origin == 'Batangas City') baseDistanceKm = 28.0;
    if (_origin == 'Rosario Batangas') baseDistanceKm = 14.5;
    if (_origin == 'Manila / PITX') baseDistanceKm = 110.0;

    double estimatedCost = 50.0;
    int estimatedMinutes = 20;

    if (_transportMode == 'Tricycle / Commute') {
      estimatedCost = baseDistanceKm * 18.0 + 30.0;
      estimatedMinutes = (baseDistanceKm * 2.2).round();
    } else if (_transportMode == 'Private Car / Taxi') {
      estimatedCost = (baseDistanceKm * 25.0) + 80.0;
      estimatedMinutes = (baseDistanceKm * 1.6).round();
    } else {
      estimatedCost = 35.0 + (baseDistanceKm > 30 ? 120.0 : 25.0);
      estimatedMinutes = (baseDistanceKm * 2.8).round() + 15;
    }

    if (estimatedMinutes < 5) estimatedMinutes = 5;
    return {
      'distance': baseDistanceKm.toStringAsFixed(1),
      'cost': estimatedCost.round(),
      'time': estimatedMinutes,
    };
  }

  @override
  Widget build(BuildContext context) {
    final allItems = TourismRepository.instance.items;
    final estimate = _calculateEstimate();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Travel Guide & Fare Estimator', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        backgroundColor: AppColors.primaryDark,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, 5)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.calculate_rounded, color: AppColors.primary, size: 24),
                      SizedBox(width: 8),
                      Text(
                        'Trip Fare & Cost Estimator',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.textDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text('Starting Location (Origin):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textMuted)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _origin,
                    items: _origins.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _origin = val);
                    },
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.bgLight,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Destination Spot in Padre Garcia:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textMuted)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<TourismItem>(
                    value: _selectedDestination,
                    items: allItems.map((item) => DropdownMenuItem(value: item, child: Text(item['title'] as String, overflow: TextOverflow.ellipsis))).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedDestination = val);
                    },
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.bgLight,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Mode of Transport:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textMuted)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _transportMode,
                    items: _transportModes.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _transportMode = val);
                    },
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.bgLight,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [AppColors.primaryDark, AppColors.primary]),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildEstimateMetric('Est. Distance', '${estimate['distance']} km'),
                        Container(width: 1, height: 32, color: Colors.white24),
                        _buildEstimateMetric('Est. Time', '${estimate['time']} mins'),
                        Container(width: 1, height: 32, color: Colors.white24),
                        _buildEstimateMetric('Est. Fare', '₱${estimate['cost']}'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Padre Garcia Travel & Visitor Guide',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: AppColors.textDark),
            ),
            const SizedBox(height: 12),
            _buildGuideCard(
              Icons.calendar_today_rounded,
              'Best Time to Visit',
              '• Fridays: Peak live cattle trading at the Livestock Auction Market (best arrived by 5:00 AM - 8:00 AM).\n• December 1st: The spectacular Kabakahan Festival featuring street parades, floats, and the Rodeo Ala Garciano.',
            ),
            const SizedBox(height: 12),
            _buildGuideCard(
              Icons.directions_bus_rounded,
              'Getting Around Town',
              '• Tricycles are the primary mode of transportation for hopping between municipal spots, lomi houses, and eco parks.\n• Jeepneys connect Padre Garcia directly to neighboring Lipa City and San Jose transport terminals.',
            ),
            const SizedBox(height: 12),
            _buildGuideCard(
              Icons.restaurant_menu_rounded,
              'Must-Try Local Cuisine',
              '• Batangas Lomi: Thick noodles loaded with pork and liver.\n• Gotong Batangas: Slow-cooked savory beef tripe soup.\n• Kapeng Barako & Tapang Taal: Traditional local breakfast pairing.',
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildEstimateMetric(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: AppColors.accentBright, fontWeight: FontWeight.w900, fontSize: 16)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildGuideCard(IconData icon, String title, String body) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: AppColors.primary, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.textDark)),
                const SizedBox(height: 6),
                Text(body, style: const TextStyle(fontSize: 13, color: Colors.black87, height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// TAB 4 — cAIttle SMART CONCIERGE
// ==========================================
class AIGuideTab extends StatefulWidget {
  const AIGuideTab({super.key});

  @override
  State<AIGuideTab> createState() => _AIGuideTabState();
}

class _AIGuideTabState extends State<AIGuideTab> with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _isTyping = false;
  late AnimationController _dotCtrl;

  final List<TourismItem> _messages = [
    {
      'sender': 'ai',
      'text': 'Mabuhay! I am cAIttle, your personal Padre Garcia concierge. Ask me anything about our cattle auctions, local lomi, or festival events!'
    }
  ];

  final List<String> _quickPrompts = [
    'Plan a 1-day trip',
    'Best Lomi & Bulalo spots?',
    'When is Kabakahan Festival?',
    'Cattle Auction Market tips',
    'How to get to Padre Garcia?',
    'Best local souvenirs to buy',
  ];

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _scrollCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendPrompt(String text) {
    if (text.trim().isEmpty || _isTyping) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text.trim()});
      _controller.clear();
      _isTyping = true;
    });
    _scrollToBottom();

    Future.delayed(const Duration(milliseconds: 750), () {
      final q = text.toLowerCase();
      String answer;

      if (q.contains('1-day') || q.contains('plan') || q.contains('itinerary')) {
        answer =
            'Here is a recommended 1-Day Padre Garcia Itinerary:\n\n'
            '• 6:30 AM: Witness live cattle trading at the Livestock Auction Market.\n'
            '• 8:30 AM: Breakfast of Tapang Taal & Kapeng Barako.\n'
            '• 10:30 AM: Sunflower picking at Pick & Go Agritourism Farm.\n'
            '• 12:30 PM: Authentic Batangas Lomi or Bulalo lunch.\n'
            '• 3:00 PM: Relaxing nature walk at Bawi Eco Trail.';
      } else if (q.contains('lomi') || q.contains('bulalo') || q.contains('food')) {
        answer =
            'Padre Garcia is famous for fresh beef dishes! Try Garciano Bulalo & Beef Kitchen for bone marrow soup, Gotong Batangas Carinderia for ginger tripe soup, and Authentic Batangas Lomi House loaded with crispy chicharon.';
      } else if (q.contains('festival') || q.contains('kabakahan')) {
        answer =
            'The Kabakahan Festival happens every December 1st! Highlights include the Rodeo Ala Garciano, street dancing (Karakol), livestock exhibits, and grand town parades.';
      } else if (q.contains('auction') || q.contains('cattle') || q.contains('market')) {
        answer =
            'The Padre Garcia Livestock Auction Market is the largest cattle trading hub in the Philippines. Fridays are the busiest market days—arrive before 8:00 AM to see the bustling trade in full swing!';
      } else if (q.contains('get to') || q.contains('transport') || q.contains('travel')) {
        answer =
            'You can reach Padre Garcia easily via bus or jeepney from Lipa City or San Jose, Batangas. Tricycles are readily available within the town center to take you to all major tourist spots!';
      } else if (q.contains('souvenir') || q.contains('pasalubong') || q.contains('buy')) {
        answer =
            'Popular local pasalubong items include authentic Batangas Barako coffee beans, homemade Tablea, local sweets, and handcrafted leather goods related to our rich cattle heritage.';
      } else {
        answer =
            'Padre Garcia, Batangas is renowned as the Cattle Trading Capital of the Philippines. You can explore our Livestock Auction Market, Pick & Go Farm, Bawi Eco Trail, and enjoy authentic Batangas Lomi!';
      }

      if (mounted) {
        setState(() {
          _isTyping = false;
          _messages.add({'sender': 'ai', 'text': answer});
        });
        _scrollToBottom();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
              ),
              child: const Icon(Icons.agriculture_rounded, color: AppColors.accentBright, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CaittleBrandText(fontSize: 18),
                    SizedBox(width: 6),
                    Text('Concierge', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                  ],
                ),
                Text('Online • Padre Garcia Smart Guide', style: TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ],
        ),
        backgroundColor: AppColors.primaryDark,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_isTyping ? 1 : 0),
              itemBuilder: (context, index) {
                if (_isTyping && index == _messages.length) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                      ),
                      child: AnimatedBuilder(
                        animation: _dotCtrl,
                        builder: (context, _) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(3, (i) {
                              final offset = math.sin((_dotCtrl.value * 2 * math.pi) + (i * 1.2));
                              return Transform.translate(
                                offset: Offset(0, -3 * offset),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                  width: 7,
                                  height: 7,
                                  decoration: const BoxDecoration(
                                    color: AppColors.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ),
                  );
                }

                final m = _messages[index];
                final isAi = m['sender'] == 'ai';
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 250),
                  builder: (context, val, child) {
                    return Opacity(
                      opacity: val,
                      child: Transform.translate(offset: Offset(0, 10 * (1 - val)), child: child),
                    );
                  },
                  child: Align(
                    alignment: isAi ? Alignment.centerLeft : Alignment.centerRight,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                      decoration: BoxDecoration(
                        gradient: isAi
                            ? null
                            : const LinearGradient(colors: [AppColors.primary, AppColors.primaryLight]),
                        color: isAi ? Colors.white : null,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(20),
                          topRight: const Radius.circular(20),
                          bottomLeft: Radius.circular(isAi ? 4 : 20),
                          bottomRight: Radius.circular(isAi ? 20 : 4),
                        ),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
                      ),
                      child: Text(
                        m['text']!,
                        style: TextStyle(
                          color: isAi ? AppColors.textDark : Colors.white,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            color: AppColors.bgLight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: _quickPrompts.map((prompt) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(
                        prompt,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primaryDark),
                      ),
                      backgroundColor: AppColors.accentSoft,
                      side: BorderSide(color: AppColors.accent.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      onPressed: () => _sendPrompt(prompt),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Ask cAIttle anything...',
                      filled: true,
                      fillColor: AppColors.bgLight,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                    onSubmitted: _sendPrompt,
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 23,
                  backgroundColor: AppColors.primary,
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.white, size: 19),
                    onPressed: () => _sendPrompt(_controller.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// TAB 5 — USER PROFILE SCREEN (VIEW & EDIT)
// ==========================================
class ProfileTab extends StatelessWidget {
  final String userEmail;
  const ProfileTab({super.key, required this.userEmail});

  void _showEditProfileDialog(BuildContext context) {
    final currentName = AuthService.getName(userEmail);
    final nameCtrl = TextEditingController(text: currentName);
    final bioCtrl = TextEditingController(text: TourismRepository.instance.userBio);
    final avatarCtrl = TextEditingController(text: TourismRepository.instance.userAvatarUrl);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Edit Profile', style: TextStyle(fontWeight: FontWeight.w900)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Display Name', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bioCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Bio / Status', prefixIcon: Icon(Icons.edit_note_rounded)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: avatarCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Profile Picture Image URL (Optional)',
                    hintText: 'https://example.com/photo.jpg',
                    prefixIcon: Icon(Icons.image_outlined),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                await TourismRepository.instance.updateProfile(
                  newName: nameCtrl.text.trim().isEmpty ? currentName : nameCtrl.text.trim(),
                  newBio: bioCtrl.text.trim(),
                  newAvatar: avatarCtrl.text.trim(),
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Profile updated successfully!'), backgroundColor: AppColors.primary),
                );
              },
              child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = AuthService.getName(userEmail);
    final isAdmin = false; // Admin badge is shown only in the dashboard after token verification.
    final repo = TourismRepository.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        backgroundColor: AppColors.primaryDark,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_rounded, color: Colors.white),
            tooltip: 'Edit Profile',
            onPressed: () => _showEditProfileDialog(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Center(
              child: Stack(
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [AppColors.primary, AppColors.accent]),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 14, offset: const Offset(0, 5)),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: ClipOval(
                        child: repo.userAvatarUrl.isNotEmpty
                            ? Image.network(
                                repo.userAvatarUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Center(
                                  child: Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                ),
                              )
                            : Container(
                                color: AppColors.primaryDark,
                                child: Center(
                                  child: Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _showEditProfileDialog(context),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(Icons.camera_alt_rounded, size: 16, color: AppColors.primaryDark),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              name,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textDark),
            ),
            const SizedBox(height: 4),
            Text(
              userEmail,
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: isAdmin ? AppColors.accentSoft : AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isAdmin ? '★ Administrator Account' : 'Verified Tourist',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: isAdmin ? const Color(0xFFB45309) : AppColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10)],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('About Me', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textMuted)),
                  const SizedBox(height: 6),
                  Text(
                    repo.userBio,
                    style: const TextStyle(fontSize: 14, color: AppColors.textDark, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10)],
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.bookmark_added_rounded, color: AppColors.primary, size: 28),
                        SizedBox(height: 8),
                        Text('Saved Trips', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                        SizedBox(height: 4),
                        Text('Active', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10)],
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.star_rounded, color: AppColors.accent, size: 28),
                        SizedBox(height: 8),
                        Text('Reviews', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                        SizedBox(height: 4),
                        Text('Community', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade50,
                  foregroundColor: Colors.red.shade700,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Sign Out', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                onPressed: () => Navigator.pushReplacementNamed(context, '/auth'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// TAB 6 — ADMIN CONTENT MANAGEMENT SYSTEM
// ==========================================
class AdminManagerTab extends StatefulWidget {
  const AdminManagerTab({super.key});

  @override
  State<AdminManagerTab> createState() => _AdminManagerTabState();
}

class _AdminManagerTabState extends State<AdminManagerTab> {
  Future<LatLng?> _pickSpotLocation(
    BuildContext context, {
    required LatLng initialLocation,
  }) {
    return showDialog<LatLng>(
      context: context,
      builder: (dialogContext) {
        LatLng previewLocation = initialLocation;
        return StatefulBuilder(
          builder: (context, setPickerState) {
            return AlertDialog(
              title: const Text('Select Exact Location'),
              content: SizedBox(
                width: 520,
                height: 440,
                child: Column(
                  children: [
                    const Text(
                      'Tap the map at the exact location of this place.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: initialLocation,
                            initialZoom: 16,
                            onTap: (tapPosition, point) {
                              setPickerState(() => previewLocation = point);
                            },
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.padregarcia.tourism',
                            ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: previewLocation,
                                  width: 48,
                                  height: 58,
                                  child: const Icon(
                                    Icons.location_pin,
                                    color: Colors.red,
                                    size: 48,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      'Lat: ${previewLocation.latitude.toStringAsFixed(7)}  |  Lng: ${previewLocation.longitude.toStringAsFixed(7)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
  onPressed: () => Navigator.pop(dialogContext, previewLocation),
  icon: const Icon(Icons.location_on),
  label: const Text('Use This Location'),
  style: ElevatedButton.styleFrom(
    backgroundColor: AppColors.primary,
    foregroundColor: Colors.white,
  ),
),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddOrEditDialog({TourismItem? existingItem}) {
    final isEdit = existingItem != null;
    final titleCtrl = TextEditingController(text: isEdit ? existingItem['title'] as String : '');
    final descCtrl = TextEditingController(text: isEdit ? existingItem['desc'] as String : '');
    final costCtrl = TextEditingController(text: isEdit ? '${existingItem['cost']}' : '0');
    String selectedCat = isEdit ? existingItem['category'] as String : 'Places';
    final existingLat = isEdit ? double.tryParse(existingItem['lat']?.toString() ?? '') : null;
    final existingLng = isEdit ? double.tryParse(existingItem['lng']?.toString() ?? '') : null;
    LatLng? selectedLocation = existingLat != null && existingLng != null
        ? LatLng(existingLat, existingLng)
        : null;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Text(
                isEdit ? 'Edit Listing' : 'Add New Tourism Spot',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'Title / Spot Name'),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCat,
                      items: ['Places', 'Food', 'Activities']
                          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) setDialogState(() => selectedCat = val);
                      },
                      decoration: const InputDecoration(labelText: 'Category'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: costCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Estimated Cost (₱)'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Description'),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await _pickSpotLocation(
                            context,
                            initialLocation: selectedLocation ?? const LatLng(13.8785, 121.2140),
                          );
                          if (picked != null) {
                            setDialogState(() => selectedLocation = picked);
                          }
                        },
                        icon: const Icon(Icons.map_outlined),
                        label: Text(selectedLocation == null
                            ? 'Select Exact Location on Map'
                            : 'Change Selected Location'),
                      ),
                    ),
                    if (selectedLocation != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Lat: ${selectedLocation!.latitude.toStringAsFixed(7)}\nLng: ${selectedLocation!.longitude.toStringAsFixed(7)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                    ] else ...[
                      const SizedBox(height: 6),
                      const Text(
                        'A map location is required before saving.',
                        style: TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    if (titleCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter the spot name.')),
                      );
                      return;
                    }
                    if (selectedLocation == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select the exact location on the map.')),
                      );
                      return;
                    }
                    final parsedCost = int.tryParse(costCtrl.text.trim()) ?? 0;

                    if (isEdit) {
                      await TourismRepository.instance.updateItem(
                        existingItem['id'] as String,
                        {
                          ...existingItem,
                          'title': titleCtrl.text.trim(),
                          'category': selectedCat,
                          'cost': parsedCost,
                          'desc': descCtrl.text.trim(),
                          'lat': selectedLocation!.latitude.toString(),
                          'lng': selectedLocation!.longitude.toString(),
                          'mapVerified': true,
                        },
                      );
                    } else {
                      await TourismRepository.instance.addItem({
                        'title': titleCtrl.text.trim(),
                        'category': selectedCat,
                        'desc': descCtrl.text.trim().isEmpty
                            ? 'Newly added Padre Garcia destination.'
                            : descCtrl.text.trim(),
                        'rating': 4.8,
                        'cost': parsedCost,
                        'hours': '8:00 AM - 5:00 PM',
                        'lat': selectedLocation!.latitude.toString(),
                        'lng': selectedLocation!.longitude.toString(),
                        'mapVerified': true,
                        'badge': 'New',
                        'featured': false,
                        'gradient': [AppColors.primary, AppColors.primaryLight],
                      });
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(isEdit ? 'Save Changes' : 'Add Spot'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = TourismRepository.instance.items;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Content Manager', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        backgroundColor: AppColors.primaryDark,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.primaryDark,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Spot', style: TextStyle(fontWeight: FontWeight.w900)),
        onPressed: () => _showAddOrEditDialog(),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3)),
              ],
            ),
            child: ListTile(
              title: Text(item['title'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('${item['category']} • ₱${item['cost']}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, color: AppColors.primary),
                    onPressed: () => _showAddOrEditDialog(existingItem: item),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: () async {
                      await TourismRepository.instance.deleteItem(item['id'] as String);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Deleted "${item['title']}"')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}