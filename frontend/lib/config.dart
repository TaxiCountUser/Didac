// Configuración de TaxiCount. Sobreescribible con --dart-define.
const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://localhost:54321',
);

const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MjAwMDAwMDAwMH0.ZxBhVEYye2lqm5NDdkey-JP6uTHcqvZriXUoBtyQniY',
);

// Backend Fastify (creación de conductores con service_role).
const backendUrl = String.fromEnvironment(
  'BACKEND_URL',
  defaultValue: 'http://localhost:3000',
);
