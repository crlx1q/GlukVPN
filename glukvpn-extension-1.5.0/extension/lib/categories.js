/*
 * Человеческое имя, иконка и цвет для кода категории домена.
 *
 * Коды приходят от управляющего сервера
 * (`control-server/src/services/domainCategories.ts`) и выглядят как
 * `streaming-music`, `vpn-control`, `ads`. Показывать их человеку нельзя —
 * а именно это и происходило: в разделе «Сайты и категории» стояли сырые
 * английские коды без иконок, и раздел выглядел сломанным.
 *
 * Тот же список повторён во Flutter
 * (`flutter-client/lib/utils/domain_categories.dart`), поэтому телефон, ПК и
 * браузер называют категорию одинаково. Если правите одну сторону — правьте
 * обе.
 *
 * Здесь только данные: имя иконки разрешает `ui/icons.js`, поэтому файл
 * остаётся пригодным и для service worker'а, где DOM нет.
 */

/** Порядок задаёт и порядок показа, если сервер прислал категории без сортировки. */
export const CATEGORY_STYLES = {
	'video': { ru: 'Видео', en: 'Video', icon: 'catVideo', color: '#ff6b81' },
	'streaming-music': { ru: 'Музыка', en: 'Music', icon: 'catMusic', color: '#3ddc97' },
	'social': { ru: 'Соцсети', en: 'Social', icon: 'catSocial', color: '#6d8bff' },
	'messaging': { ru: 'Мессенджеры', en: 'Messengers', icon: 'catChat', color: '#4fc3f7' },
	'gaming': { ru: 'Игры', en: 'Gaming', icon: 'catGame', color: '#a06bff' },
	'search': { ru: 'Поиск', en: 'Search', icon: 'catSearch', color: '#ffc964' },
	'shopping': { ru: 'Покупки', en: 'Shopping', icon: 'catShop', color: '#ffa36b' },
	'cloud': { ru: 'Облака и сервисы', en: 'Cloud services', icon: 'catCloud', color: '#8ab4f8' },
	'dev': { ru: 'Разработка', en: 'Developer', icon: 'code', color: '#7de2d1' },
	'ads': { ru: 'Реклама и трекеры', en: 'Ads and tracking', icon: 'catAds', color: '#b0bad6' },
	'adult': { ru: '18+', en: 'Adult', icon: 'catAdult', color: '#d16ba5' },
	'torrent': { ru: 'Торренты', en: 'Torrents', icon: 'catTorrent', color: '#9fe870' },
	'vpn-control': { ru: 'Служебный трафик GlukVPN', en: 'GlukVPN service traffic', icon: 'key', color: '#6d8bff' },
	'other': { ru: 'Прочее', en: 'Other', icon: 'globe', color: '#8b95b8' },
}

/** Незнакомый код: «streaming-music» -> «Streaming music». */
function humanise(code) {
	const cleaned = code.replace(/[-_]+/g, ' ').trim()
	if (!cleaned) return code
	return cleaned[0].toUpperCase() + cleaned.slice(1)
}

/*
 * Оформление для кода категории. Никогда не возвращает null.
 *
 * Незнакомый код показывается как есть, а не как «Прочее»: подписать чужой
 * трафик прочим — это тихо соврать о том, что человек видит в статистике.
 * Новая категория с сервера поэтому не требует обновления расширения.
 */
export function categoryStyle(code) {
	const key = String(code ?? '').trim().toLowerCase()
	if (!key) return CATEGORY_STYLES.other
	const known = CATEGORY_STYLES[key]
	if (known) return known
	const human = humanise(key)
	return { ru: human, en: human, icon: 'catTag', color: '#8b95b8' }
}

/** Короткая подпись категории на языке интерфейса. */
export function categoryLabel(code, russian) {
	const style = categoryStyle(code)
	return russian ? style.ru : style.en
}
