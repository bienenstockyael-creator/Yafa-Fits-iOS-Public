import Foundation
import Supabase

// The anon key is a public client key — safe to embed in the app binary.
// It only grants access scoped by Row Level Security policies.
enum SupabaseConfig {
    static let url = URL(string: "https://dqvwutzoakfmnhbsefsw.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRxdnd1dHpvYWtmbW5oYnNlZnN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUzNDQzMDUsImV4cCI6MjA5MDkyMDMwNX0.PWe0-qve1pz9dZilQ1FUwFphcvqXy6N-vr4qj5pKRvI"
}

let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey
)
