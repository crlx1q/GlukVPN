/* ==========================================================================
   GlukVPN site config - ЕДИНСТВЕННОЕ место, где меняются цены, регионы,
   ссылки на загрузки и контакты. HTML/CSS трогать не нужно.

   Важно: здесь нет и не должно быть внутренних данных инфраструктуры
   (имён нод, портов, API-эндпоинтов, диагностики). Только публичные,
   маркетинговые значения.
   ========================================================================== */

window.GLUK_CONFIG = {
  /* Версия сайта. Идёт вместе с бета-каналом: beta 0.3.0. */
  release: { version: "0.3.1", channel: "beta", date: "2026-08-22" },

  /* ------------------------------------------------------------- аккаунт ---
     Сайт ходит в тот же control plane, что и приложение.
     channel: "beta" — тестовый канал, "prod" — боевой.
     Переключается одной строкой здесь, больше нигде менять не нужно.  */
  api: {
    channel: "beta",
    base: { prod: "https://api.gluk.tech", beta: "https://beta-api.gluk.tech" },
    timeoutMs: 12000,
  },
  auth: {
    enabled: true,
    /* Саморегистрация выключена и на сервере (AppConfig.selfRegistrationEnabled
       в Flutter = false): аккаунты создаются админом. Когда появится
       подтверждение через Telegram — ставим true.                          */
    selfRegistration: false,
    /* Маршруты будущего веб-приложения — сайт их не занимает. */
    accountUrl: "/login/",
    webAppUrl: "",
    /* Куда вести после входа: "" — остаться на /login/ и показать кабинет. */
    afterLogin: "",
  },
  ui: {
    /* Маленький бейдж BETA рядом с логотипом и панель выбора шрифта.
       На релизе оба ставятся в false.                                     */
    channelBadge: true,
    fontPicker: true,
  },

  site: {
    name: "GlukVPN",
    domain: "vpn.gluk.tech",
    url: "https://vpn.gluk.tech",
    tagline: "Быстрый и приватный VPN",
    telegram: "https://t.me/glukvpn",
    telegramLabel: "@glukvpn",
    supportEmail: "support@gluk.tech",
  },

  /* ---------------------------------------------------------- загрузки ---
     status: "available" | "soon"
     url: прямая ссылка на сборку. Пока пусто -> кнопка ведёт на /download/
     и показывает честный статус, ничего не обещая.                       */
  downloads: {
    android: {
      status: "available",
      label: "Android",
      version: "",
      url: "", // TODO: указать ссылку на APK, когда сборка опубликована
      note: "Android 8.0 и новее",
    },
    googlePlay: { status: "soon", label: "Google Play", url: "", note: "На модерации" },
    windows: { status: "soon", label: "Windows", url: "", note: "В разработке" },
    ios: { status: "soon", label: "iOS", url: "", note: "В разработке" },
    macos: { status: "soon", label: "macOS", url: "", note: "В разработке" },
    chrome: { status: "soon", label: "Расширение для Chrome", url: "", note: "В разработке" },
  },

  /* ------------------------------------------------------------- тарифы ---
     Цены предварительные. Меняются только здесь.                          */
  pricing: {
    currency: "₸",
    currencyPosition: "after", // "after" -> 1 990 ₸
    period: "мес",
    note: "Цены предварительные и могут измениться до публичного запуска. Оплата и списания появятся вместе с релизом биллинга.",
    plans: [
      {
        id: "free",
        name: "Free",
        price: 0,
        priceLabel: "0",
        badge: "",
        tagline: "Попробовать без оплаты",
        cta: { label: "Начать бесплатно", href: "/download/" },
        features: [
          { text: "1 регион на выбор системы", on: true },
          { text: "1 устройство", on: true },
          { text: "Ограниченная скорость", on: true },
          { text: "Kill switch", on: false },
          { text: "Приоритетная поддержка", on: false },
        ],
      },
      {
        id: "basic",
        name: "Basic",
        price: 1490,
        priceLabel: "1 490",
        badge: "Популярный",
        featured: true,
        tagline: "Для повседневного использования",
        cta: { label: "Выбрать Basic", href: "/pricing/" },
        features: [
          { text: "Все доступные регионы", on: true },
          { text: "До 3 устройств", on: true },
          { text: "Полная скорость канала", on: true },
          { text: "Kill switch и DNS-защита", on: true },
          { text: "Приоритетная поддержка", on: false },
        ],
      },
      {
        id: "pro",
        name: "Pro",
        price: 2490,
        priceLabel: "2 490",
        badge: "",
        tagline: "Для семьи и всех устройств",
        cta: { label: "Выбрать Pro", href: "/pricing/" },
        features: [
          { text: "Все регионы + ранний доступ к новым", on: true },
          { text: "До 10 устройств", on: true },
          { text: "Полная скорость канала", on: true },
          { text: "Kill switch и DNS-защита", on: true },
          { text: "Приоритетная поддержка", on: true },
        ],
      },
    ],
  },

  /* ------------------------------------------------------------ регионы ---
     lat/lon используются и глобусом, и картой сети.
     ping/load - типовые ориентировочные значения для визуального языка
     (как в приложении), не живая телеметрия.                              */
  network: {
    home: { id: "you", name: "Вы", lat: 48.0, lon: 68.0, flag: "🇰🇿" },
    nodes: [
      {
        id: "de",
        name: "Германия",
        city: "Франкфурт",
        flag: "🇩🇪",
        lat: 50.11,
        lon: 8.68,
        status: "live",
        ping: 24,
        load: 32,
      },
      {
        id: "fr",
        name: "Франция",
        city: "Париж",
        flag: "🇫🇷",
        lat: 48.86,
        lon: 2.35,
        status: "live",
        ping: 29,
        load: 27,
      },
      {
        id: "us",
        name: "США",
        city: "Нью-Йорк",
        flag: "🇺🇸",
        lat: 40.71,
        lon: -74.01,
        status: "live",
        ping: 96,
        load: 41,
      },
      { id: "nl", name: "Нидерланды", city: "Амстердам", flag: "🇳🇱", lat: 52.37, lon: 4.9, status: "soon" },
      { id: "tr", name: "Турция", city: "Стамбул", flag: "🇹🇷", lat: 41.01, lon: 28.98, status: "soon" },
      { id: "sg", name: "Сингапур", city: "Сингапур", flag: "🇸🇬", lat: 1.35, lon: 103.82, status: "soon" },
      { id: "jp", name: "Япония", city: "Токио", flag: "🇯🇵", lat: 35.68, lon: 139.69, status: "soon" },
    ],
  },
};
