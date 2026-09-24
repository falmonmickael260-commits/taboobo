import RoomClient from "./RoomClient";

/**
 * Server Component : dans Next 15 `params` est une Promise.
 * Aucune dependance a Supabase ici -> aucun risque d'erreur de prerender.
 */
export default async function RoomPage({
  params,
}: {
  params: Promise<{ code: string }>;
}) {
  const { code } = await params;
  return <RoomClient code={decodeURIComponent(code).toUpperCase()} />;
}
