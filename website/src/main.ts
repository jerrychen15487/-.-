import "./assets/css/main.css";
import { createApp } from "vue";
import { createRouter, createWebHashHistory } from "vue-router";
import ui from "@nuxt/ui/vue-plugin";
import App from "./App.vue";
import Library from "./pages/Library.vue";
import Device from "./pages/Device.vue";
import Help from "./pages/Help.vue";
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", component: Library },
    { path: "/device", component: Device },
    { path: "/help", component: Help },
    { path: "/:pathMatch(.*)*", redirect: "/" },
  ],
});
createApp(App).use(router).use(ui).mount("#app");
