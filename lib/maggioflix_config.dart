/// MaggioFlix: impostazioni del fork, tutte in un file così gli aggiornamenti
/// di Plezy restano facili da integrare.
library;

/// Indirizzi Jellyfin precompilati nella schermata di accesso. Uno per riga:
/// l'app usa quello raggiungibile con la latenza più bassa (in casa la rete
/// locale, fuori il dominio pubblico).
const String maggioflixJellyfinUrls = 'http://192.168.1.65:8096\nhttps://jellyfin.maggioflix.com';

/// Indirizzo Seerr precompilato nella schermata di collegamento.
const String maggioflixSeerrUrl = 'https://seerr.maggioflix.com';

/// I tracker (Trakt, MyAnimeList, AniList, Simkl, MDBList) e il caricamento
/// dei log passano da servizi registrati dal progetto Plezy, che un fork
/// distribuito non deve usare (vedi TRADEMARKS.md). Restano nascosti.
const bool maggioflixUsesPlezyServices = false;

/// Accesso iniziale: MaggioFlix usa solo Plex (niente Jellyfin/Emby).
const bool maggioflixAllowMediaBrowserLogin = false;

/// La scheda Live TV resta nascosta dalla barra di navigazione.
const bool maggioflixShowLiveTvTab = false;

/// Richieste Seerr semplificate: si sceglie solo normale o 4K, senza server,
/// profilo qualità, cartella, lingua o tag (Seerr usa i suoi predefiniti).
const bool maggioflixAllowAdvancedRequests = false;
