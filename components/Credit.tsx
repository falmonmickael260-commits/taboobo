"use client";

/**
 * Signature de l'auteur du jeu. Affichee sur l'accueil, dans le lobby,
 * pendant la partie et sur l'ecran de fin.
 */
export default function Credit({
  variant = "compact",
}: {
  variant?: "compact" | "hero";
}) {
  if (variant === "hero") {
    return (
      <footer className="mt-8 flex flex-col items-center gap-3 animate-slide-up">
        <span
          aria-hidden
          className="h-px w-24 bg-gradient-to-r from-transparent via-white/25 to-transparent"
        />
        <p className="text-[11px] font-black uppercase tracking-[0.3em] text-slate-500">
          By{" "}
          <span className="bg-gradient-to-r from-teamA-glow via-white to-teamB-glow bg-clip-text text-transparent">
            LewisHalmito
          </span>
        </p>
      </footer>
    );
  }

  return (
    <footer className="pt-6 pb-2">
      <p className="text-center text-[10px] font-black uppercase tracking-[0.28em] text-slate-600">
        By <span className="text-slate-400">LewisHalmito</span>
      </p>
    </footer>
  );
}
