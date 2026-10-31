# Hackintosh Fixer

App nativa macOS per aiutare a configurare Hackintosh Intel e OpenCore.

## Funzioni

- Rileva CPU e dispositivi PCI, USB, grafica e archiviazione con `system_profiler`.
- Supporta OpenAI, Anthropic Claude e Google Gemini. Le chiavi API sono salvate nel Portachiavi macOS.
- Analizza hardware e riepilogo dei kext e propone modifiche verificabili a `config.plist`.
- Dopo l'analisi AI, propone kext dal catalogo ufficiale in base ai componenti rilevati; puoi rivedere e deselezionare ogni proposta.
- Scarica release ZIP da un catalogo limitato di repository GitHub ufficiali: Lilu, VirtualSMC, WhateverGreen, AppleALC e IntelMausi.
- Scarica i kext scelti e le dipendenze necessarie, poi li installa in un unico piano in `EFI/OC/Kexts` e aggiorna `Kernel → Add`.
- Crea un backup di `config.plist` prima di ogni modifica e chiede conferma prima di scrivere nell'EFI.
- Offre un riavvio esplicito, dopo conferma dell'utente e richiesta di autorizzazione macOS.
- Usa `icon.png` come icona dell'app macOS e Liquid Glass su macOS 26 con SDK/toolchain compatibili; sulle versioni precedenti mostra superfici traslucide di fallback.
- Al primo avvio raccoglie modello del PC/scheda madre, versione macOS e altri dettagli hardware, poi provider/modello AI e chiave API. L'interfaccia è una chat in inglese o italiano con impostazioni modificabili.

## Sicurezza e limiti

Prima del download e dell'installazione controlli il piano proposto. L'installazione batch richiede una singola autorizzazione amministratore nel prompt di macOS; l'app non installa un helper root permanente e non esegue comandi forniti dall'AI. Se l'autorizzazione viene negata, l'operazione non viene eseguita.

Il catalogo è volutamente limitato: i kext devono corrispondere al tuo hardware, alla versione di macOS e alla configurazione OpenCore. Il supporto alle dipendenze è esplicito e conservativo; installa prima quelle indicate dall'app. Non sostituisce kext già presenti. Dopo aver copiato un kext nell'EFI, non è necessario ricostruire la cache delle estensioni macOS: OpenCore lo carica all'avvio. Gli installer di driver di terze parti non vengono eseguiti automaticamente; puoi aprire la relativa pagina ufficiale e seguirne le istruzioni.

Il rapporto hardware, con UUID e seriali rimossi, e il riepilogo dei kext sono inviati al provider AI scelto. Non viene inviato il contenuto completo di `config.plist`. I download dei kext avvengono direttamente dalle release GitHub dei repository elencati nel catalogo.

## Requisiti e avvio

- Mac Intel con macOS 13 o successivo
- Xcode 26 / Swift 6.2 per Liquid Glass nativo; Swift 5.9 o successivo per le altre funzioni
- Chiave API per il provider AI scelto
- Volume EFI montato e configurazione OpenCore esistente

Dalla cartella del progetto:

```sh
swift run
```

La build crea `HackintoshFixer.app` (un'applicazione macOS, `CFBundlePackageType=APPL`, non un kext) per Mac Intel usando `icon.png` come icona, poi crea un DMG compresso con un collegamento ad Applicazioni per installarla trascinandola. GitHub Actions pubblica il file DMG come artifact su push, pull request e avvio manuale.

Al primo avvio inserisci il modello del PC/build o della scheda madre, la versione macOS e gli altri dettagli hardware; poi scegli provider e modello e inserisci la chiave API. Si apre la chat bilingue: invia una richiesta per avviare la scansione dei componenti e ricevere un'analisi che include il profilo salvato. Seleziona il volume EFI con `EFI/OC/config.plist` per abilitare le modifiche OpenCore. Seleziona i kext consigliati, scaricali e controlla versioni e dipendenze; quindi scegli **Autorizza e installa** e approva il prompt macOS. In Impostazioni puoi modificare successivamente lingua, dettagli del PC, provider, modello e chiave API.
