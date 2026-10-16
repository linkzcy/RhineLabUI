import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rollupOptions: {
      input: "wallpaper.html",
    },
    outDir: "dist-wallpaper",
    emptyOutDir: true,
  },
});
