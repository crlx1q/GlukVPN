/* ==========================================================================
   GlukVPN site config - ЕДИНСТВЕННОЕ место, где меняются цены, регионы,
   ссылки на загрузки и контакты. HTML/CSS трогать не нужно.

   Важно: здесь нет и не должно быть внутренних данных инфраструктуры
   (имён нод, портов, API-эндпоинтов, диагностики). Только публичные,
   маркетинговые значения.
   ========================================================================== */

window.GLUK_CONFIG = {
  /* Версия сайта. Идёт вместе с бета-каналом: beta 0.3.0. */
  release: { version: "0.6.0", channel: "beta", date: "2026-08-25" },

  /* ------------------------------------------------------------- аккаунт ---
     Сайт ходит в тот же control plane, что и приложение.
     channel: "beta" — тестовый канал, "prod" — боевой.
     Переключается одной строкой здесь, больше нигде менять не нужно.

     Это значение по умолчанию. Страница /link/ может его переопределить
     параметром ?api=prod|beta: подтверждать вход обязательно нужно на том
     же инстансе API, который выдал ссылку, иначе кода там просто нет
     (память у prod и beta раздельная) и пользователь видит «ссылка не
     найдена». Переопределение живёт только во вкладке (sessionStorage).  */
  api: {
    channel: "prod",
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
    accountUrl: "/app/",
    webAppUrl: "",
    /* Куда вести после входа: "" — остаться на /login/ и показать кабинет. */
    afterLogin: "",
  },
  ui: {
    /* Маленький бейдж BETA рядом с логотипом и панель выбора шрифта.
       На релизе оба ставятся в false.                                     */
    channelBadge: false,
    fontPicker: false,
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
    home: { id: "you", name: "Вы", lat: 48.0, lon: 68.0, flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#00AFCA'/><circle cx='11.4' cy='7' r='2.5' fill='#FEC50C'/><g stroke='#FEC50C' stroke-width='.7' stroke-linecap='round'><path d='M11.4 3.1v.9M11.4 10v.9M7.5 7h.9M14.4 7h.9M8.6 4.2l.65.65M13.55 9.15l.65.65M14.2 4.2l-.65.65M9.25 9.15l-.65.65'/></g><path d='M6.9 12.1c1.4-1.1 3.1-1.7 4.5-1.7s3.1.6 4.5 1.7c-1.5-.5-3-.75-4.5-.75s-3 .25-4.5.75z' fill='#FEC50C'/><rect x='1.2' y='3' width='1.5' height='10' rx='.7' fill='#FEC50C' opacity='.85'/></svg>" },
    nodes: [
      {
        id: "de",
        name: "Германия",
        city: "Франкфурт",
        flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#111'/><rect y='5.33' width='24' height='5.34' fill='#D00'/><rect y='10.67' width='24' height='5.33' fill='#FFCE00'/></svg>",
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
        flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#F4F5F7'/><rect width='8' height='16' fill='#0B3E9C'/><rect x='16' width='8' height='16' fill='#E1273B'/></svg>",
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
        flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#F4F5F7'/><g fill='#D02F44'><rect y='0' width='24' height='1.23'/><rect y='2.46' width='24' height='1.23'/><rect y='4.92' width='24' height='1.23'/><rect y='7.38' width='24' height='1.23'/><rect y='9.85' width='24' height='1.23'/><rect y='12.31' width='24' height='1.23'/><rect y='14.77' width='24' height='1.23'/></g><rect width='10.4' height='8.6' fill='#2A3560'/><g fill='#fff'><circle cx='1.9' cy='1.7' r='.62'/><circle cx='4.6' cy='1.7' r='.62'/><circle cx='7.3' cy='1.7' r='.62'/><circle cx='3.2' cy='3.6' r='.62'/><circle cx='5.9' cy='3.6' r='.62'/><circle cx='8.6' cy='3.6' r='.62'/><circle cx='1.9' cy='5.5' r='.62'/><circle cx='4.6' cy='5.5' r='.62'/><circle cx='7.3' cy='5.5' r='.62'/><circle cx='3.2' cy='7.3' r='.62'/><circle cx='5.9' cy='7.3' r='.62'/><circle cx='8.6' cy='7.3' r='.62'/></g></svg>",
        lat: 40.71,
        lon: -74.01,
        status: "live",
        ping: 96,
        load: 41,
      },
      { id: "nl", name: "Нидерланды", city: "Амстердам", flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#C8102E'/><rect y='10.67' width='24' height='5.33' fill='#1E4785'/></svg>", lat: 52.37, lon: 4.9, status: "soon" },
      { id: "tr", name: "Турция", city: "Стамбул", flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#E30A17'/><circle cx='9.4' cy='8' r='4' fill='#fff'/><circle cx='10.9' cy='8' r='3.2' fill='#E30A17'/><path d='M15.1 8l-1.7.55 1.05-1.45v1.8L15.1 8l1.05 1.45-1.7-.55' fill='#fff'/><path d='M14.6 6.2l.62 1.62 1.73.08-1.35 1.08.45 1.68-1.45-.95-1.45.95.45-1.68-1.35-1.08 1.73-.08z' fill='#fff'/></svg>", lat: 41.01, lon: 28.98, status: "soon" },
      { id: "sg", name: "Сингапур", city: "Сингапур", flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='8' fill='#EF3340'/><circle cx='6.2' cy='4' r='2.9' fill='#fff'/><circle cx='7.7' cy='4' r='2.6' fill='#EF3340'/><g fill='#fff'><circle cx='9.9' cy='2.1' r='.52'/><circle cx='12.1' cy='2.1' r='.52'/><circle cx='11' cy='3.6' r='.52'/><circle cx='9.3' cy='4.6' r='.52'/><circle cx='12.7' cy='4.6' r='.52'/></g></svg>", lat: 1.35, lon: 103.82, status: "soon" },
      { id: "jp", name: "Япония", city: "Токио", flag: "<svg class='flag-ic' viewBox='0 0 24 16' role='img' aria-hidden='true' focusable='false'><rect width='24' height='16' fill='#F4F5F7'/><circle cx='12' cy='8' r='4.6' fill='#BC002D'/></svg>", lat: 35.68, lon: 139.69, status: "soon" },
    ],
  },
};
