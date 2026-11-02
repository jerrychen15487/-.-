import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import ui from "@nuxt/ui/vite";
export default defineConfig({
  base: "/piano-score-library/",
  plugins: [
    vue(),
    ui({
      // Custom surfaces are light; system dark mode must not invert component text.
      colorMode: false,
      ui: {
        colors: { primary: "teal", neutral: "slate" },
        button: {
          compoundVariants: [
            {
              color: "primary",
              variant: "solid",
              class: { base: "hover:bg-[#126456] active:bg-[#0f5549]" },
            },
            {
              color: "error",
              variant: "solid",
              class: { base: "hover:bg-[#912018] active:bg-[#761b15]" },
            },
          ],
        },
      },
    }),
  ],
  build: { chunkSizeWarningLimit: 850 },
});
