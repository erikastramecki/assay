import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

// @assay/sui-sdk is imported as first-party source so Vite transpiles its TS.
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@assay/sui-sdk": fileURLToPath(new URL("../sui-sdk/src/index.ts", import.meta.url)) },
    // the aliased SDK source + dapp-kit must share ONE @mysten/sui instance (else two
    // Transaction classes → wallet signing breaks). Force a single copy from web/node_modules.
    dedupe: ["@mysten/sui", "@mysten/dapp-kit", "@mysten/bcs", "@tanstack/react-query", "react", "react-dom"],
  },
  server: { port: 5173 },
});
