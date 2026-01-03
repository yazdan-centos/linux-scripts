-- Cleans all application tables and resets identity/sequence counters.

-- 1) Truncate all tables with FK cascade and reset identity values
TRUNCATE TABLE
  cost_shares,
  reservation,
  guest,
  daily_meal_dish,
  daily_meal,
  personnel,
  dish,
  users_roles,
  roles_privileges,
  users,
  role,
  privilege,
  cost_center,
  app_settings
RESTART IDENTITY CASCADE;

-- 2) Reset explicit sequences (used by privilege, role, users)
ALTER SEQUENCE IF EXISTS privilege_seq RESTART WITH 1;
ALTER SEQUENCE IF EXISTS role_seq RESTART WITH 1;
ALTER SEQUENCE IF EXISTS users_seq RESTART WITH 1;