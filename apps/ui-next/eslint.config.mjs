// eslint.config.mjs
import { dirname } from "path";
import { fileURLToPath } from "url";
import { FlatCompat } from "@eslint/eslintrc";

import tseslint from "@typescript-eslint/eslint-plugin";
import tsparser from "@typescript-eslint/parser";
import unusedImports from "eslint-plugin-unused-imports";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const compat = new FlatCompat({
  baseDirectory: __dirname,
});

export default [
  // Next.js + TS Basis (via compat)
  ...compat.extends("next/core-web-vitals", "next/typescript"),

  // Eigene Regeln & Plugins
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsparser,
    },
    plugins: {
      "@typescript-eslint": tseslint,
      "unused-imports": unusedImports,
    },
    rules: {
      // Sauberkeit
      "unused-imports/no-unused-imports": "warn",
      "no-console": ["warn", { allow: ["warn", "error"] }],

      // TS-spezifisch
      "@typescript-eslint/ban-ts-comment": "off",

      // React/JSX
      "react/jsx-key": "warn",
    },
  },
];
