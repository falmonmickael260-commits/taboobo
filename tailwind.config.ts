import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        ink: { 900: "#07070f", 800: "#0d0d1c", 700: "#141428", 600: "#1d1d38" },
        teamA: { DEFAULT: "#22d3ee", soft: "#0e7490", glow: "#67e8f9" },
        teamB: { DEFAULT: "#fb7185", soft: "#9f1239", glow: "#fda4af" },
        gold: "#fbbf24",
      },
      fontFamily: {
        display: ["var(--font-display)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        glow: "0 0 40px -8px rgb(34 211 238 / 0.45)",
        glowB: "0 0 40px -8px rgb(251 113 133 / 0.45)",
        card: "0 24px 60px -18px rgb(0 0 0 / 0.75)",
      },
      keyframes: {
        pop: {
          "0%": { opacity: "0", transform: "scale(.88) translateY(14px)" },
          "60%": { opacity: "1", transform: "scale(1.02) translateY(0)" },
          "100%": { opacity: "1", transform: "scale(1) translateY(0)" },
        },
        "slide-up": {
          "0%": { opacity: "0", transform: "translateY(16px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        shake: {
          "0%,100%": { transform: "translateX(0) rotate(0deg)" },
          "20%": { transform: "translateX(-9px) rotate(-1.5deg)" },
          "40%": { transform: "translateX(9px) rotate(1.5deg)" },
          "60%": { transform: "translateX(-6px) rotate(-1deg)" },
          "80%": { transform: "translateX(6px) rotate(1deg)" },
        },
        bump: {
          "0%": { transform: "scale(1)" },
          "45%": { transform: "scale(1.35)" },
          "100%": { transform: "scale(1)" },
        },
        "flash-in": {
          "0%": { opacity: "0", transform: "scale(.6)" },
          "25%": { opacity: "1", transform: "scale(1.06)" },
          "75%": { opacity: "1", transform: "scale(1)" },
          "100%": { opacity: "0", transform: "scale(1.1)" },
        },
        breathe: {
          "0%,100%": { opacity: ".45", transform: "scale(1)" },
          "50%": { opacity: ".8", transform: "scale(1.08)" },
        },
        "tick-warn": {
          "0%,100%": { transform: "scale(1)", color: "#fb7185" },
          "50%": { transform: "scale(1.12)", color: "#ef4444" },
        },
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" },
        },
      },
      animation: {
        pop: "pop .45s cubic-bezier(.2,.9,.3,1.2) both",
        "slide-up": "slide-up .35s ease-out both",
        shake: "shake .55s cubic-bezier(.36,.07,.19,.97) both",
        bump: "bump .45s ease-out",
        "flash-in": "flash-in 1.1s ease-out both",
        breathe: "breathe 3.5s ease-in-out infinite",
        "tick-warn": "tick-warn 1s ease-in-out infinite",
        shimmer: "shimmer 2.4s linear infinite",
      },
    },
  },
  plugins: [],
};

export default config;
