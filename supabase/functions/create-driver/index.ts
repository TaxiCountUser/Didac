// ============================================================
// Supabase Edge Function: create-driver  (ALTERNATIVA a Fastify)
//
// La Fase 1 usa el endpoint Fastify POST /api/v1/drivers como camino
// ACTIVO (ya está en el docker-compose y cubierto por los tests).
// Esta función Edge es el equivalente para quien prefiera desplegar
// con `supabase functions deploy create-driver`. No se ejecuta en el
// stack local actual (no incluimos el contenedor edge-runtime).
//
// Misma lógica: verifica que el llamante sea Owner (con su JWT) y crea
// el driver con service_role + metadata { role, tenant_id }.
// ============================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function tempPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(9));
  const b64 = btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "");
  return `Tx${b64}9!`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
  if (!token) {
    return new Response(JSON.stringify({ error: "Falta token" }), { status: 401 });
  }

  const { email, name } = await req.json().catch(() => ({}));
  if (!email) {
    return new Response(JSON.stringify({ error: "email es obligatorio" }), { status: 400 });
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Verificar el llamante
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: "Token inválido" }), { status: 401 });
  }

  // 2. Comprobar que es Owner
  const { data: caller } = await admin
    .from("users")
    .select("role, tenant_id")
    .eq("id", userData.user.id)
    .single();
  if (!caller || caller.role !== "owner") {
    return new Response(JSON.stringify({ error: "Solo un Owner puede invitar" }), { status: 403 });
  }

  // 3. Crear el driver
  const password = tempPassword();
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { role: "driver", tenant_id: caller.tenant_id, name: name ?? null },
  });
  if (createErr) {
    return new Response(JSON.stringify({ error: createErr.message }), { status: 400 });
  }

  console.log(`[create-driver] ${email} creado en tenant ${caller.tenant_id}. Pwd temporal: ${password}`);

  return new Response(
    JSON.stringify({ id: created.user.id, email, tenant_id: caller.tenant_id, tempPassword: password }),
    { status: 201, headers: { "Content-Type": "application/json" } },
  );
});
