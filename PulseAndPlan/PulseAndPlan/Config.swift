import Foundation

/// Live Pair Mode credentials. Paste your project's values from Supabase → Project Settings → API,
/// run `schema.sql` once in the SQL editor, then switch to Live Pair in Settings.
enum Config {
    static let SUPABASE_URL = ""        // e.g. "https://abcdefgh.supabase.co"
    static let SUPABASE_ANON_KEY = ""   // the public "anon" key, never the service_role key

    static var isSupabaseConfigured: Bool {
        URL(string: SUPABASE_URL)?.host != nil && !SUPABASE_ANON_KEY.isEmpty
    }
}
