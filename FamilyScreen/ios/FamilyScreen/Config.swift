import Foundation

/// Supabase project used only as a live relay (Realtime broadcast, no tables).
/// Must match SUPABASE_HOST / SUPABASE_KEY in the Android app's CaptureService.java.
enum Config {
    static let SUPABASE_URL = "https://pkcocejpyjphjtqgkoli.supabase.co"
    static let SUPABASE_ANON_KEY = "sb_publishable_T1JWV4I67eMM53CK3XCTcQ_Tw7QP4iS" // publishable: safe in an app
}
