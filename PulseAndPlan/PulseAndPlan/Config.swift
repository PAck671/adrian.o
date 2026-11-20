import Foundation

/// Live Pair Mode credentials. Paste your project's values from Supabase → Project Settings → API,
/// run `schema.sql` once in the SQL editor, then switch to Live Pair in Settings.
enum Config {
    static let SUPABASE_URL = "https://pkcocejpyjphjtqgkoli.supabase.co"
    static let SUPABASE_ANON_KEY = "sb_publishable_T1JWV4I67eMM53CK3XCTcQ_Tw7QP4iS" // publishable: safe in an app; never a secret key

    static var isSupabaseConfigured: Bool {
        URL(string: SUPABASE_URL)?.host != nil && !SUPABASE_ANON_KEY.isEmpty
    }
}
