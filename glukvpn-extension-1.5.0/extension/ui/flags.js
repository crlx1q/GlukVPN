/*
 * Country flags as real SVG artwork - never emoji.
 *
 * Windows has no colour flag glyphs, which is why the emoji version looked
 * empty in the server list. The first eight bodies are copied verbatim from the
 * website's own icon set (site/assets/js/config.js, class `flag-ic`) so the
 * extension, vpn.gluk.tech and the mobile app show identical artwork. The rest
 * are drawn on the same 24x16 grid in the same flat style.
 */

const BODIES = {
	/* ---- verbatim from the site ---- */
	KZ:
		"<rect width='24' height='16' fill='#00AFCA'/><circle cx='11.4' cy='7' r='2.5' fill='#FEC50C'/><g stroke='#FEC50C' stroke-width='.7' stroke-linecap='round'><path d='M11.4 3.1v.9M11.4 10v.9M7.5 7h.9M14.4 7h.9M8.6 4.2l.65.65M13.55 9.15l.65.65M14.2 4.2l-.65.65M9.25 9.15l-.65.65'/></g><path d='M6.9 12.1c1.4-1.1 3.1-1.7 4.5-1.7s3.1.6 4.5 1.7c-1.5-.5-3-.75-4.5-.75s-3 .25-4.5.75z' fill='#FEC50C'/><rect x='1.2' y='3' width='1.5' height='10' rx='.7' fill='#FEC50C' opacity='.85'/>",
	DE: "<rect width='24' height='16' fill='#111'/><rect y='5.33' width='24' height='5.34' fill='#D00'/><rect y='10.67' width='24' height='5.33' fill='#FFCE00'/>",
	FR: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='8' height='16' fill='#0B3E9C'/><rect x='16' width='8' height='16' fill='#E1273B'/>",
	US:
		"<rect width='24' height='16' fill='#F4F5F7'/><g fill='#D02F44'><rect y='0' width='24' height='1.23'/><rect y='2.46' width='24' height='1.23'/><rect y='4.92' width='24' height='1.23'/><rect y='7.38' width='24' height='1.23'/><rect y='9.85' width='24' height='1.23'/><rect y='12.31' width='24' height='1.23'/><rect y='14.77' width='24' height='1.23'/></g><rect width='10.4' height='8.6' fill='#2A3560'/><g fill='#fff'><circle cx='1.9' cy='1.7' r='.62'/><circle cx='4.6' cy='1.7' r='.62'/><circle cx='7.3' cy='1.7' r='.62'/><circle cx='3.2' cy='3.6' r='.62'/><circle cx='5.9' cy='3.6' r='.62'/><circle cx='8.6' cy='3.6' r='.62'/><circle cx='1.9' cy='5.5' r='.62'/><circle cx='4.6' cy='5.5' r='.62'/><circle cx='7.3' cy='5.5' r='.62'/><circle cx='3.2' cy='7.3' r='.62'/><circle cx='5.9' cy='7.3' r='.62'/><circle cx='8.6' cy='7.3' r='.62'/></g>",
	NL: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#C8102E'/><rect y='10.67' width='24' height='5.33' fill='#1E4785'/>",
	TR:
		"<rect width='24' height='16' fill='#E30A17'/><circle cx='9.4' cy='8' r='4' fill='#fff'/><circle cx='10.9' cy='8' r='3.2' fill='#E30A17'/><path d='M14.6 6.2l.62 1.62 1.73.08-1.35 1.08.45 1.68-1.45-.95-1.45.95.45-1.68-1.35-1.08 1.73-.08z' fill='#fff'/>",
	SG:
		"<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='8' fill='#EF3340'/><circle cx='6.2' cy='4' r='2.9' fill='#fff'/><circle cx='7.7' cy='4' r='2.6' fill='#EF3340'/><g fill='#fff'><circle cx='9.9' cy='2.1' r='.52'/><circle cx='12.1' cy='2.1' r='.52'/><circle cx='11' cy='3.6' r='.52'/><circle cx='9.3' cy='4.6' r='.52'/><circle cx='12.7' cy='4.6' r='.52'/></g>",
	JP: "<rect width='24' height='16' fill='#F4F5F7'/><circle cx='12' cy='8' r='4.6' fill='#BC002D'/>",

	/* ---- same grid, same flat style ---- */
	GB:
		"<rect width='24' height='16' fill='#012169'/><path d='M0 0l24 16M24 0L0 16' stroke='#fff' stroke-width='3.2'/><path d='M0 0l24 16M24 0L0 16' stroke='#C8102E' stroke-width='1.9'/><path d='M12 0v16M0 8h24' stroke='#fff' stroke-width='5.4'/><path d='M12 0v16M0 8h24' stroke='#C8102E' stroke-width='3.2'/>",
	PL: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='8' width='24' height='8' fill='#DC143C'/>",
	SE: "<rect width='24' height='16' fill='#006AA7'/><rect x='7' width='3' height='16' fill='#FECC00'/><rect y='6.5' width='24' height='3' fill='#FECC00'/>",
	FI: "<rect width='24' height='16' fill='#F4F5F7'/><rect x='7' width='3.4' height='16' fill='#003580'/><rect y='6.3' width='24' height='3.4' fill='#003580'/>",
	NO: "<rect width='24' height='16' fill='#BA0C2F'/><rect x='6.4' width='4.2' height='16' fill='#fff'/><rect y='5.9' width='24' height='4.2' fill='#fff'/><rect x='7.6' width='1.8' height='16' fill='#00205B'/><rect y='7.1' width='24' height='1.8' fill='#00205B'/>",
	DK: "<rect width='24' height='16' fill='#C8102E'/><rect x='7' width='3' height='16' fill='#fff'/><rect y='6.5' width='24' height='3' fill='#fff'/>",
	CH: "<rect width='24' height='16' fill='#D52B1E'/><rect x='10.6' y='4' width='2.8' height='8' fill='#fff'/><rect x='8' y='6.6' width='8' height='2.8' fill='#fff'/>",
	IT: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='8' height='16' fill='#008C45'/><rect x='16' width='8' height='16' fill='#CD212A'/>",
	ES: "<rect width='24' height='16' fill='#AA151B'/><rect y='4' width='24' height='8' fill='#F1BF00'/>",
	PT: "<rect width='24' height='16' fill='#DA291C'/><rect width='9.6' height='16' fill='#046A38'/><circle cx='9.6' cy='8' r='3.1' fill='#FFE900' stroke='#DA291C' stroke-width='.6'/>",
	IE: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='8' height='16' fill='#169B62'/><rect x='16' width='8' height='16' fill='#FF883E'/>",
	AT: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#ED2939'/><rect y='10.67' width='24' height='5.33' fill='#ED2939'/>",
	CZ: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='8' width='24' height='8' fill='#D7141A'/><path d='M0 0l11 8-11 8z' fill='#11457E'/>",
	RO: "<rect width='24' height='16' fill='#FCD116'/><rect width='8' height='16' fill='#002B7F'/><rect x='16' width='8' height='16' fill='#CE1126'/>",
	HU: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#CD2A3E'/><rect y='10.67' width='24' height='5.33' fill='#436F4D'/>",
	BG: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='5.33' width='24' height='5.34' fill='#00966E'/><rect y='10.67' width='24' height='5.33' fill='#D62612'/>",
	GR:
		"<rect width='24' height='16' fill='#F4F5F7'/><g fill='#0D5EAF'><rect y='0' width='24' height='1.78'/><rect y='3.56' width='24' height='1.78'/><rect y='7.11' width='24' height='1.78'/><rect y='10.67' width='24' height='1.78'/><rect y='14.22' width='24' height='1.78'/></g><rect width='8.9' height='8.9' fill='#0D5EAF'/><path d='M3.7 0h1.5v8.9H3.7z' fill='#fff'/><path d='M0 3.7h8.9v1.5H0z' fill='#fff'/>",
	HR: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#FF0000'/><rect y='10.67' width='24' height='5.33' fill='#171796'/>",
	RS: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#C6363C'/><rect y='5.33' width='24' height='5.34' fill='#0C4076'/>",
	SK: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='5.33' width='24' height='5.34' fill='#0B4EA2'/><rect y='10.67' width='24' height='5.33' fill='#EE1C25'/>",
	SI: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='5.33' width='24' height='5.34' fill='#0000AA'/><rect y='10.67' width='24' height='5.33' fill='#D50000'/>",
	LT: "<rect width='24' height='16' fill='#FDB913'/><rect y='5.33' width='24' height='5.34' fill='#006A44'/><rect y='10.67' width='24' height='5.33' fill='#C1272D'/>",
	LV: "<rect width='24' height='16' fill='#9E3039'/><rect y='6.6' width='24' height='2.8' fill='#fff'/>",
	EE: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#0072CE'/><rect y='5.33' width='24' height='5.34' fill='#000'/>",
	UA: "<rect width='24' height='16' fill='#FFD700'/><rect width='24' height='8' fill='#0057B7'/>",
	BY: "<rect width='24' height='16' fill='#4AA657'/><rect width='24' height='10.4' fill='#C8313E'/><rect width='4.4' height='16' fill='#fff'/><path d='M1.1 1.6l1.1 1.6-1.1 1.6L0 3.2z' fill='#C8313E'/><path d='M3.3 6.4l1.1 1.6-1.1 1.6-1.1-1.6z' fill='#C8313E'/><path d='M1.1 11.2l1.1 1.6-1.1 1.6L0 12.8z' fill='#C8313E'/>",
	RU: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='5.33' width='24' height='5.34' fill='#0039A6'/><rect y='10.67' width='24' height='5.33' fill='#D52B1E'/>",
	MD: "<rect width='24' height='16' fill='#FFD200'/><rect width='8' height='16' fill='#0046AE'/><rect x='16' width='8' height='16' fill='#CC092F'/>",
	GE: "<rect width='24' height='16' fill='#F4F5F7'/><rect x='10.2' width='3.6' height='16' fill='#FF0000'/><rect y='6.2' width='24' height='3.6' fill='#FF0000'/><g fill='#FF0000'><rect x='4' y='2.4' width='2.4' height='.9'/><rect x='4.75' y='1.65' width='.9' height='2.4'/><rect x='17.6' y='2.4' width='2.4' height='.9'/><rect x='18.35' y='1.65' width='.9' height='2.4'/><rect x='4' y='12.7' width='2.4' height='.9'/><rect x='4.75' y='11.95' width='.9' height='2.4'/><rect x='17.6' y='12.7' width='2.4' height='.9'/><rect x='18.35' y='11.95' width='.9' height='2.4'/></g>",
	AM: "<rect width='24' height='16' fill='#F2A800'/><rect width='24' height='5.33' fill='#D90012'/><rect y='5.33' width='24' height='5.34' fill='#0033A0'/>",
	AZ: "<rect width='24' height='16' fill='#509E2F'/><rect width='24' height='5.33' fill='#00B5E2'/><rect y='5.33' width='24' height='5.34' fill='#EF3340'/><circle cx='11.4' cy='8' r='2.1' fill='#fff'/><circle cx='12.2' cy='8' r='1.7' fill='#EF3340'/>",
	KG: "<rect width='24' height='16' fill='#E8112D'/><circle cx='12' cy='8' r='3.4' fill='none' stroke='#FFEF00' stroke-width='1.1'/><circle cx='12' cy='8' r='1.5' fill='#FFEF00'/>",
	UZ:
		"<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5' fill='#0099B5'/><rect y='11' width='24' height='5' fill='#1EB53A'/><circle cx='4.6' cy='2.5' r='1.6' fill='#fff'/><circle cx='5.4' cy='2.5' r='1.4' fill='#0099B5'/>",
	TJ: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#CC0000'/><rect y='10.67' width='24' height='5.33' fill='#006600'/>",
	TM: "<rect width='24' height='16' fill='#28AE66'/><rect x='3.4' width='3' height='16' fill='#D22630'/>",
	AE: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#00732F'/><rect y='10.67' width='24' height='5.33' fill='#000'/><rect width='6.4' height='16' fill='#FF0000'/>",
	IL: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='1.6' width='24' height='2' fill='#0038B8'/><rect y='12.4' width='24' height='2' fill='#0038B8'/><path d='M12 4.6l2.9 5H9.1z' fill='none' stroke='#0038B8' stroke-width='.85'/><path d='M12 11.4l-2.9-5h5.8z' fill='none' stroke='#0038B8' stroke-width='.85'/>",
	EG: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#CE1126'/><rect y='10.67' width='24' height='5.33' fill='#000'/><circle cx='12' cy='8' r='1.7' fill='#C09300'/>",
	ZA: "<rect width='24' height='16' fill='#002395'/><rect width='24' height='8' fill='#DE3831'/><path d='M0 0l9 8-9 8z' fill='#007A4D'/><path d='M0 2.2l6.6 5.8L0 13.8z' fill='#FFB612'/><path d='M0 4.4l4.2 3.6L0 11.6z' fill='#000'/>",
	IN: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#FF9933'/><rect y='10.67' width='24' height='5.33' fill='#138808'/><circle cx='12' cy='8' r='2' fill='none' stroke='#000080' stroke-width='.65'/><circle cx='12' cy='8' r='.5' fill='#000080'/>",
	CN:
		"<rect width='24' height='16' fill='#DE2910'/><path d='M4.4 2.1l.72 2.2H7.4l-1.87 1.36.71 2.2-1.84-1.36-1.87 1.36.72-2.2L1.4 4.3h2.29z' fill='#FFDE00'/><g fill='#FFDE00'><circle cx='9.2' cy='2' r='.62'/><circle cx='11' cy='3.6' r='.62'/><circle cx='11' cy='5.9' r='.62'/><circle cx='9.2' cy='7.5' r='.62'/></g>",
	HK: "<rect width='24' height='16' fill='#DE2910'/><circle cx='12' cy='8' r='3.2' fill='#fff'/><circle cx='12' cy='8' r='1.5' fill='#DE2910'/>",
	KR: "<rect width='24' height='16' fill='#F4F5F7'/><circle cx='12' cy='8' r='3.4' fill='#CD2E3A'/><path d='M8.6 8a3.4 3.4 0 0 1 6.8 0 1.7 1.7 0 0 0-3.4 0 1.7 1.7 0 0 1-3.4 0z' fill='#0047A0'/><g stroke='#000' stroke-width='.55'><path d='M3.6 4.2l1.7 2.4M5 3.2l1.7 2.4M20.4 11.8l-1.7-2.4M19 12.8l-1.7-2.4'/></g>",
	TH: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='2.7' fill='#A51931'/><rect y='13.3' width='24' height='2.7' fill='#A51931'/><rect y='5.3' width='24' height='5.4' fill='#2D2A4A'/>",
	VN: "<rect width='24' height='16' fill='#DA251D'/><path d='M12 4.2l1.24 3.8h4l-3.24 2.36 1.24 3.8L12 11.8l-3.24 2.36 1.24-3.8L6.76 8h4z' fill='#FFFF00'/>",
	ID: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='8' fill='#CE1126'/>",
	MY: "<rect width='24' height='16' fill='#F4F5F7'/><g fill='#CC0001'><rect y='0' width='24' height='1.14'/><rect y='2.29' width='24' height='1.14'/><rect y='4.57' width='24' height='1.14'/><rect y='6.86' width='24' height='1.14'/><rect y='9.14' width='24' height='1.14'/><rect y='11.43' width='24' height='1.14'/><rect y='13.71' width='24' height='1.14'/></g><rect width='12' height='9.14' fill='#010066'/><circle cx='5.4' cy='4.6' r='2.5' fill='#FFCC00'/><circle cx='6.6' cy='4.6' r='2.1' fill='#010066'/>",
	AU: "<rect width='24' height='16' fill='#012169'/><rect width='11' height='8' fill='#012169'/><path d='M0 0l11 8M11 0L0 8' stroke='#fff' stroke-width='1.7'/><path d='M5.5 0v8M0 4h11' stroke='#fff' stroke-width='2.7'/><path d='M5.5 0v8M0 4h11' stroke='#C8102E' stroke-width='1.6'/><g fill='#fff'><circle cx='17' cy='10.4' r='1.1'/><circle cx='19.6' cy='4.4' r='.75'/><circle cx='20.8' cy='8.4' r='.75'/><circle cx='17.4' cy='5.6' r='.6'/><circle cx='19.6' cy='12.4' r='.6'/></g>",
	NZ: "<rect width='24' height='16' fill='#012169'/><path d='M0 0l11 8M11 0L0 8' stroke='#fff' stroke-width='1.7'/><path d='M5.5 0v8M0 4h11' stroke='#fff' stroke-width='2.7'/><path d='M5.5 0v8M0 4h11' stroke='#C8102E' stroke-width='1.6'/><g fill='#C8102E' stroke='#fff' stroke-width='.35'><circle cx='19.4' cy='4.4' r='.7'/><circle cx='20.9' cy='8' r='.7'/><circle cx='17.6' cy='8.6' r='.7'/><circle cx='19.4' cy='12' r='.7'/></g>",
	CA: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='6' height='16' fill='#D80621'/><rect x='18' width='6' height='16' fill='#D80621'/><path d='M12 3.4l1 2.4 1.9-.9-.7 2.3 2.1.3-1.7 1.4.6 1.3-2.2-.4.1 2.6h-.2l.1-2.6-2.2.4.6-1.3-1.7-1.4 2.1-.3-.7-2.3 1.9.9z' fill='#D80621'/>",
	MX: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='8' height='16' fill='#006847'/><rect x='16' width='8' height='16' fill='#CE1126'/><circle cx='12' cy='8' r='1.9' fill='none' stroke='#8C6239' stroke-width='.7'/>",
	BR: "<rect width='24' height='16' fill='#009B3A'/><path d='M12 1.9l9.4 6.1L12 14.1 2.6 8z' fill='#FEDF00'/><circle cx='12' cy='8' r='3.1' fill='#002776'/><path d='M9.1 7.1a9 9 0 0 1 5.9 1.6' fill='none' stroke='#fff' stroke-width='.75'/>",
	AR: "<rect width='24' height='16' fill='#F4F5F7'/><rect width='24' height='5.33' fill='#74ACDF'/><rect y='10.67' width='24' height='5.33' fill='#74ACDF'/><circle cx='12' cy='8' r='1.6' fill='#F6B40E'/>",
	CL: "<rect width='24' height='16' fill='#F4F5F7'/><rect y='8' width='24' height='8' fill='#D52B1E'/><rect width='8' height='8' fill='#0039A6'/><path d='M4 1.9l.9 2.7h2.8L5.4 6.3l.9 2.7L4 7.3 1.7 9l.9-2.7L.3 4.6h2.8z' fill='#fff'/>",
	CO: "<rect width='24' height='16' fill='#FCD116'/><rect y='8' width='24' height='4' fill='#003893'/><rect y='12' width='24' height='4' fill='#CE1126'/>",
}

/* The control plane sends `country` as a display name, not always a code. This
 * is why the list showed the globe placeholder for every row. */
const NAME_TO_CODE = {
	kazakhstan: 'KZ', казахстан: 'KZ', qazaqstan: 'KZ',
	germany: 'DE', германия: 'DE', deutschland: 'DE',
	france: 'FR', франция: 'FR',
	'united states': 'US', usa: 'US', 'united states of america': 'US', сша: 'US', америка: 'US',
	netherlands: 'NL', нидерланды: 'NL', holland: 'NL', голландия: 'NL',
	turkey: 'TR', türkiye: 'TR', turkiye: 'TR', турция: 'TR',
	singapore: 'SG', сингапур: 'SG',
	japan: 'JP', япония: 'JP',
	'united kingdom': 'GB', uk: 'GB', england: 'GB', britain: 'GB', 'great britain': 'GB',
	великобритания: 'GB', англия: 'GB',
	poland: 'PL', польша: 'PL',
	sweden: 'SE', швеция: 'SE',
	finland: 'FI', финляндия: 'FI',
	norway: 'NO', норвегия: 'NO',
	denmark: 'DK', дания: 'DK',
	switzerland: 'CH', швейцария: 'CH',
	italy: 'IT', италия: 'IT',
	spain: 'ES', испания: 'ES',
	portugal: 'PT', португалия: 'PT',
	ireland: 'IE', ирландия: 'IE',
	austria: 'AT', австрия: 'AT',
	czechia: 'CZ', 'czech republic': 'CZ', чехия: 'CZ',
	romania: 'RO', румыния: 'RO',
	hungary: 'HU', венгрия: 'HU',
	bulgaria: 'BG', болгария: 'BG',
	greece: 'GR', греция: 'GR',
	croatia: 'HR', хорватия: 'HR',
	serbia: 'RS', сербия: 'RS',
	slovakia: 'SK', словакия: 'SK',
	slovenia: 'SI', словения: 'SI',
	lithuania: 'LT', литва: 'LT',
	latvia: 'LV', латвия: 'LV',
	estonia: 'EE', эстония: 'EE',
	ukraine: 'UA', украина: 'UA',
	belarus: 'BY', беларусь: 'BY', белоруссия: 'BY',
	russia: 'RU', 'russian federation': 'RU', россия: 'RU',
	moldova: 'MD', молдова: 'MD',
	georgia: 'GE', грузия: 'GE',
	armenia: 'AM', армения: 'AM',
	azerbaijan: 'AZ', азербайджан: 'AZ',
	kyrgyzstan: 'KG', киргизия: 'KG', кыргызстан: 'KG',
	uzbekistan: 'UZ', узбекистан: 'UZ',
	tajikistan: 'TJ', таджикистан: 'TJ',
	turkmenistan: 'TM', туркменистан: 'TM',
	'united arab emirates': 'AE', uae: 'AE', оаэ: 'AE', эмираты: 'AE',
	israel: 'IL', израиль: 'IL',
	egypt: 'EG', египет: 'EG',
	'south africa': 'ZA', 'южная африка': 'ZA', юар: 'ZA',
	india: 'IN', индия: 'IN',
	china: 'CN', китай: 'CN',
	'hong kong': 'HK', гонконг: 'HK',
	'south korea': 'KR', korea: 'KR', 'republic of korea': 'KR', корея: 'KR',
	thailand: 'TH', таиланд: 'TH',
	vietnam: 'VN', вьетнам: 'VN',
	indonesia: 'ID', индонезия: 'ID',
	malaysia: 'MY', малайзия: 'MY',
	australia: 'AU', австралия: 'AU',
	'new zealand': 'NZ', 'новая зеландия': 'NZ',
	canada: 'CA', канада: 'CA',
	mexico: 'MX', мексика: 'MX',
	brazil: 'BR', бразилия: 'BR',
	argentina: 'AR', аргентина: 'AR',
	chile: 'CL', чили: 'CL',
	colombia: 'CO', колумбия: 'CO',
}

/* Some payloads only carry a city. Better a right flag than a grey globe. */
const CITY_TO_CODE = {
	frankfurt: 'DE', berlin: 'DE', munich: 'DE', франкфурт: 'DE',
	paris: 'FR', париж: 'FR',
	amsterdam: 'NL', амстердам: 'NL',
	london: 'GB', лондон: 'GB',
	'new york': 'US', ashburn: 'US', 'los angeles': 'US', chicago: 'US', dallas: 'US', miami: 'US',
	istanbul: 'TR', стамбул: 'TR',
	singapore: 'SG',
	tokyo: 'JP', токио: 'JP',
	almaty: 'KZ', astana: 'KZ', qyzylorda: 'KZ', kyzylorda: 'KZ', shymkent: 'KZ', aqtobe: 'KZ',
	алматы: 'KZ', астана: 'KZ', кызылорда: 'KZ', шымкент: 'KZ',
	warsaw: 'PL', варшава: 'PL',
	stockholm: 'SE', helsinki: 'FI', oslo: 'NO', copenhagen: 'DK',
	zurich: 'CH', geneva: 'CH', vienna: 'AT', prague: 'CZ',
	milan: 'IT', rome: 'IT', madrid: 'ES', lisbon: 'PT', dublin: 'IE',
	moscow: 'RU', москва: 'RU', 'saint petersburg': 'RU',
	kyiv: 'UA', kiev: 'UA', киев: 'UA',
	minsk: 'BY', tbilisi: 'GE', yerevan: 'AM', baku: 'AZ',
	bishkek: 'KG', tashkent: 'UZ', ташкент: 'UZ',
	dubai: 'AE', дубай: 'AE',
	mumbai: 'IN', delhi: 'IN', seoul: 'KR', 'hong kong': 'HK',
	sydney: 'AU', melbourne: 'AU', toronto: 'CA', montreal: 'CA',
	'sao paulo': 'BR', 'são paulo': 'BR',
}

const GLOBE =
	"<rect width='24' height='16' rx='2' fill='#1b1626'/><circle cx='12' cy='8' r='5' fill='none' stroke='#8b7cf6' stroke-width='1.1'/><path d='M7 8h10M12 3.2c2 1.7 2 7.9 0 9.6-2-1.7-2-7.9 0-9.6z' fill='none' stroke='#8b7cf6' stroke-width='1.1'/>"

const NS = 'http://www.w3.org/2000/svg'

/**
 * Accepts anything the API might send: 'kz', 'KZ', 'Kazakhstan', 'Казахстан',
 * or a whole node record. Returns a two-letter code or ''.
 */
export function countryCodeOf(value, city) {
	if (value && typeof value === 'object') {
		return countryCodeOf(
			value.countryCode ?? value.country_code ?? value.country ?? value.cc,
			value.city ?? value.location ?? city,
		)
	}
	const raw = String(value ?? '').trim()
	if (raw.length === 2 && /^[a-z]{2}$/i.test(raw)) {
		const up = raw.toUpperCase()
		if (BODIES[up]) return up
	}
	const key = raw.toLowerCase()
	if (NAME_TO_CODE[key]) return NAME_TO_CODE[key]
	const cityKey = String(city ?? '').trim().toLowerCase()
	if (cityKey && CITY_TO_CODE[cityKey]) return CITY_TO_CODE[cityKey]
	return ''
}

export function hasFlag(code) {
	return Boolean(BODIES[countryCodeOf(code)])
}

export function flagMarkup(code, size = 22, city) {
	const resolved = countryCodeOf(code, city)
	const body = BODIES[resolved] ?? GLOBE
	const h = Math.round((size * 16) / 24)
	return `<svg xmlns="${NS}" class="flag-ic" viewBox="0 0 24 16" width="${size}" height="${h}" role="img" aria-hidden="true" focusable="false">${body}</svg>`
}

/*
 * Returns a real <svg> element.
 *
 * This used to go through DOMParser with the image/svg+xml MIME type, which is
 * exactly why the flags disappeared: the markup carried no xmlns declaration,
 * so the parsed root landed in the null namespace and rendered as nothing at
 * all - invisible, but with no error anywhere. The element is now built the
 * same way icons.js builds its own, which is the one path already proven to
 * render inside this popup: create the root in the SVG namespace, then let the
 * HTML parser fill in the children.
 */
export function flagSvg(code, size = 22, city) {
	const resolved = countryCodeOf(code, city)
	const body = BODIES[resolved] ?? GLOBE
	const svg = document.createElementNS(NS, 'svg')
	svg.setAttribute('class', 'flag-ic')
	svg.setAttribute('viewBox', '0 0 24 16')
	svg.setAttribute('width', String(size))
	svg.setAttribute('height', String(Math.round((size * 16) / 24)))
	svg.setAttribute('role', 'img')
	svg.setAttribute('aria-hidden', 'true')
	svg.setAttribute('focusable', 'false')
	svg.innerHTML = body
	return svg
}

// Convenience used by the popup: drop a flag into a holder element.
export function paintFlag(holder, code, size = 22, city) {
	if (!holder) return
	holder.replaceChildren(flagSvg(code, size, city))
}
