//
//  SupabaseConfig.swift
//  Baccarat
//
//  Public credentials for the Supabase project. The anon key is *designed*
//  to be public — security is enforced by RLS on the Postgres side.
//  See /supabase-config.js (web) for the matching values.
//

import Foundation

enum SupabaseConfig {
    static let url = URL(string: "https://wwutjnqchxzdfxmhfaaj.supabase.co")!
    static let anonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind3dXRqbnFjaHh6ZGZ4bWhmYWFqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg2MjMwMTcsImV4cCI6MjA5NDE5OTAxN30.JeealVciyofN8NrTWFXOrqznKAPInldkRiJ7tm7fk4Y"
}
