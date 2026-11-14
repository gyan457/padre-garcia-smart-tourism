PADRE GARCIA SMART TOURISM — GLOBAL SYNC PATCH

FILES
- main_global.dart: updated app source. Copy to lib/main.dart.
- pubspec_global.yaml: copy over pubspec.yaml.
- firestore.rules: publish in Firebase Console > Firestore Database > Rules.

IMPORTANT
1. Keep your existing lib/firebase_options.dart and android/app/google-services.json.
2. Run: flutter pub get
3. Run: flutter run
4. Deploy firestore.rules in Firebase Console. Without the rules, the app may fail to read/write.
5. The app uses Firebase Auth and Firestore. Internet access is required for cross-device sync.
6. Admin access now requires a Firebase custom claim named admin=true. An email address alone no longer grants admin access. Set this claim using a trusted Firebase Admin SDK environment; never put service-account credentials in the Flutter app.
7. New Firebase projects start with an empty tourism_spots collection. Add official Padre Garcia destinations using an account with the admin claim.
8. The existing map coordinates have NOT been changed because the supplied code does not provide verified coordinates for every destination. Do not publish unverified pins as accurate.
9. Before Google Play release, configure a private release keystore and signing configuration. Do not publish with the debug key.

WHAT WAS UPDATED
- Tourism spot listings continue to be shared through Firestore.
- Reviews and ratings are now stored in Firestore and shared across users/devices.
- Profile name, bio, and avatar URL are saved under each user's private Firestore document.
- My Trip itinerary and visited status are saved per account and sync across devices.
- Admin checks use Firebase ID-token custom claims instead of trusting a hard-coded email.

NOTE: I could not run flutter analyze/build because the full Android project and local Flutter SDK environment were not available in this session. Test on your machine before distribution.
