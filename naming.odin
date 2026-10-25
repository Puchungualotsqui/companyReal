package main

// Automatic place names. A kingdom is assigned a language group and draws all
// of its town names from that group's pool. Conquered towns keep the name they
// were founded with, so a kingdom can end up ruling towns from several
// cultures, just like real realms do.

NAME_LENGTH :: 32

// Largest town pool, used to reserve names for the whole match.
TOWN_NAME_POOL_MAX :: 512

Name :: [NAME_LENGTH]u8

TownCulture :: enum {
	Spanish,
	Portuguese,
	French,
	Italian,
	German,
	Dutch,
	Nordic,
	English,
}

// Real place names (ASCII spelling) grouped by language rather than by modern
// country, so Spanish, Portuguese, German, etc. each mix several regions. The
// pools are long enough that a single match cannot exhaust them.
TOWN_NAMES := [TownCulture][]string {
	.Spanish = {
		"Madrid", "Toledo", "Sevilla", "Granada", "Valencia", "Zaragoza", "Malaga", "Murcia",
		"Bilbao", "Alicante", "Valladolid", "Vigo", "Gijon", "Cadiz", "Cordoba", "Santander",
		"Pamplona", "Salamanca", "Burgos", "Albacete", "Logrono", "Badajoz", "Huelva", "Jaen",
		"Leon", "Ourense", "Lugo", "Oviedo", "Palencia", "Segovia", "Soria", "Teruel",
		"Cuenca", "Guadalajara", "Avila", "Zamora", "Caceres", "Almeria", "Motril", "Ronda",
		"Antequera", "Estepa", "Utrera", "Ecija", "Jerez", "Tarifa", "Algeciras", "Marbella",
		"Fuengirola", "Torremolinos", "Benalmadena", "Nerja", "Adra", "Roquetas", "Elche", "Orihuela",
		"Torrevieja", "Denia", "Gandia", "Sagunto", "Castellon", "Vinaros", "Tortosa", "Tarragona",
		"Reus", "Lleida", "Girona", "Figueres", "Vic", "Manresa", "Terrassa", "Sabadell",
		"Mataro", "Blanes", "Olot", "Ripoll", "Puigcerda", "Jaca", "Huesca", "Calatayud",
		"Tarazona", "Tudela", "Estella", "Laguardia", "Barakaldo", "Getxo", "Portugalete", "Santurtzi",
		"Irun", "Eibar", "Durango", "Laredo", "Torrelavega", "Reinosa", "Mondonedo", "Ribadeo",
		"Viveiro", "Ferrol", "Betanzos", "Santiago", "Pontevedra", "Tui", "Verin", "Monforte",
		"Ponferrada", "Astorga", "Benavente", "Toro", "Aranda", "Miranda", "Haro", "Calahorra",
		"Arnedo", "Alfaro", "Almazan", "Medinaceli", "Siguenza", "Molina", "Talavera", "Illescas",
		"Aranjuez", "Alcala", "Colmenar", "Chinchon", "Arcos", "Osuna", "Carmona", "Lebrija",
		"Santa Cruz", "Chiquitos", "Warnes", "Cotoca", "Porongo", "Montero", "Portachuelo", "San Julian",
		"Pailon", "Okinawa", "Mineros", "Yapacani", "El Torno", "Buena Vista", "Samaipata", "Vallegrande",
		"Mairana", "Comarapa", "Robore", "Camiri", "Charagua", "Villamontes", "Yacuiba", "Guayaramerin",
		"Riberalta", "Cobija", "Guarayos", "Trinidad", "San Ignacio", "San Ramon", "San Borja", "Rurrenabaque",
		"Puerto Suarez", "San Matias", "San Jose de Chiquitos", "Tarija", "Trujillo", "Arequipa", "Cusco",
		"Quito", "Loja", "Ambato", "Riobamba", "Bogota", "Tunja", "Pasto", "Popayan",
		"Cali", "Medellin", "Cartagena", "Monterrey", "Puebla", "Oaxaca", "Merida", "Campeche",
		"Veracruz", "Zacatecas", "Guanajuato", "Morelia", "Toluca", "Xalapa", "Rosario", "Mendoza",
		"Salta", "Jujuy", "Tucuman", "Parana", "Corrientes", "Resistencia", "Posadas", "Neuquen",
		"Bariloche", "Trelew", "Rawson", "Ushuaia", "Valparaiso", "Concepcion", "Temuco", "Antofagasta",
		"Iquique", "Arica",
	},
	.Portuguese = {
		"Lisboa", "Porto", "Braga", "Coimbra", "Aveiro", "Faro", "Evora", "Beja",
		"Setubal", "Santarem", "Leiria", "Viseu", "Guarda", "Braganca", "Chaves", "Vila Real",
		"Barcelos", "Guimaraes", "Fafe", "Amarante", "Penafiel", "Viana", "Esposende", "Ponte Lima",
		"Valenca", "Moncao", "Melgaco", "Foz Coa", "Pinhel", "Trancoso", "Covilha", "Fundao",
		"Castelo Branco", "Abrantes", "Tomar", "Entroncamento", "Torres Novas", "Rio Maior", "Caldas", "Alcobaca",
		"Nazare", "Obidos", "Peniche", "Lourinha", "Mafra", "Sintra", "Cascais", "Oeiras",
		"Almada", "Sesimbra", "Palmela", "Montijo", "Barreiro", "Seixal", "Coruche", "Estremoz",
		"Elvas", "Portalegre", "Nisa", "Marvao", "Castelo Vide", "Arronches", "Moura", "Serpa",
		"Mertola", "Alcoutim", "Tavira", "Olhao", "Loule", "Quarteira", "Albufeira", "Portimao",
		"Lagos", "Silves", "Monchique", "Aljezur", "Odemira", "Sines", "Grandola", "Rio Janeiro",
		"Niteroi", "Santos", "Campinas", "Sorocaba", "Ribeirao", "Piracicaba", "Bauru", "Marilia",
		"Aracatuba", "Sao Jose", "Taubate", "Guaratingueta", "Lorena", "Barra Mansa", "Volta Redonda", "Petropolis",
		"Teresopolis", "Nova Friburgo", "Cabo Frio", "Macae", "Vitoria", "Vila Velha", "Serra", "Cariacica",
		"Linhares", "Sao Mateus", "Teixeira", "Eunapolis", "Ilheus", "Itabuna", "Jequie", "Alagoinhas",
		"Camacari", "Salvador", "Lauro", "Aracaju", "Maceio", "Recife", "Olinda", "Caruaru",
		"Garanhuns", "Petrolina", "Juazeiro", "Fortaleza", "Sobral", "Crato", "Natal", "Campina Grande",
		"Belem", "Ananindeua", "Maraba", "Manaus", "Parintins", "Itacoatiara", "Boa Vista", "Macapa",
		"Palmas", "Goiania", "Anapolis", "Brasilia", "Cuiaba", "Rondonopolis", "Campo Grande", "Dourados",
		"Corumba", "Coxim", "Porto Velho", "Rio Branco", "Curitiba", "Londrina", "Maringa", "Ponta Grossa",
		"Cascavel", "Foz Iguacu", "Guarapuava", "Florianopolis", "Joinville", "Blumenau", "Itajai", "Criciuma",
		"Chapeco", "Lages", "Caxias Sul", "Pelotas", "Santa Maria", "Uruguaiana", "Bage", "Passo Fundo",
		"Erechim", "Novo Hamburgo", "Canoas", "Gravatai", "Viamao",
	},
	.French = {
		"Paris", "Lyon", "Marseille", "Toulouse", "Nice", "Nantes", "Montpellier", "Strasbourg",
		"Bordeaux", "Lille", "Rennes", "Reims", "Le Havre", "Saint Etienne", "Toulon", "Grenoble",
		"Dijon", "Angers", "Nimes", "Villeurbanne", "Clermont", "Le Mans", "Aix", "Brest",
		"Tours", "Amiens", "Limoges", "Annecy", "Perpignan", "Besancon", "Metz", "Orleans",
		"Rouen", "Mulhouse", "Caen", "Nancy", "Argenteuil", "Montreuil", "Roubaix", "Tourcoing",
		"Avignon", "Poitiers", "Nanterre", "Versailles", "Pau", "La Rochelle", "Calais", "Cannes",
		"Antibes", "Saint Nazaire", "Colmar", "Bourges", "Quimper", "Valence", "Chambery", "Troyes",
		"Lorient", "Beauvais", "Cholet", "Vannes", "La Roche", "Niort", "Bayonne", "Chartres",
		"Laval", "Blois", "Arles", "Frejus", "Albi", "Carcassonne", "Beziers", "Narbonne",
		"Sete", "Montauban", "Auch", "Tarbes", "Dax", "Biarritz", "Angouleme", "Perigueux",
		"Brive", "Aurillac", "Rodez", "Cahors", "Agen", "Marmande", "Villeneuve", "Bergerac",
		"Sarlat", "Rochefort", "Cognac", "Saintes", "Royan", "Fontenay", "Saumur", "Chinon",
		"Vendome", "Evreux", "Lisieux", "Cherbourg", "Granville", "Saint Malo", "Dinan", "Fougeres",
		"Vitre", "Mayenne", "Alencon", "Flers", "Argentan", "Falaise", "Honfleur", "Deauville",
		"Trouville", "Etretat", "Dieppe", "Abbeville", "Arras", "Lens", "Bethune", "Douai",
		"Valenciennes", "Cambrai", "Maubeuge", "Charleville", "Sedan", "Verdun", "Epinal", "Belfort",
		"Montbeliard", "Thionville", "Sarrebourg", "Haguenau", "Saverne", "Wissembourg", "Obernai", "Selestat",
		"Guebwiller", "Thann", "Namur", "Liege", "Charleroi", "Bruges", "Gand", "Anvers",
		"Mons", "Tournai", "Louvain", "Malines", "Quebec", "Montreal", "Gatineau", "Sherbrooke",
		"Trois Rivieres", "Saguenay", "Rimouski", "Drummondville",
	},
	.Italian = {
		"Roma", "Milano", "Napoli", "Torino", "Palermo", "Genova", "Bologna", "Firenze",
		"Bari", "Catania", "Venezia", "Verona", "Messina", "Padova", "Trieste", "Taranto",
		"Brescia", "Parma", "Prato", "Modena", "Reggio", "Perugia", "Ravenna", "Livorno",
		"Cagliari", "Foggia", "Rimini", "Salerno", "Ferrara", "Sassari", "Latina", "Monza",
		"Siracusa", "Pescara", "Bergamo", "Forli", "Trento", "Vicenza", "Terni", "Bolzano",
		"Novara", "Piacenza", "Ancona", "Andria", "Arezzo", "Udine", "Cesena", "Lecce",
		"Pesaro", "Barletta", "Alessandria", "La Spezia", "Pisa", "Catanzaro", "Pistoia", "Lucca",
		"Brindisi", "Como", "Treviso", "Varese", "Asti", "Grosseto", "Potenza", "Massa",
		"Carrara", "Imola", "Cremona", "Savona", "Benevento", "Matera", "Viterbo", "Avellino",
		"Aosta", "Belluno", "Biella", "Cuneo", "Lodi", "Mantova", "Pavia", "Rovigo",
		"Sondrio", "Verbania", "Vercelli", "Enna", "Ragusa", "Trapani", "Agrigento", "Caltanissetta",
		"Crotone", "Cosenza", "Vibo", "Caserta", "Isernia", "Campobasso", "Chieti", "Aquila",
		"Teramo", "Ascoli", "Fermo", "Macerata", "Urbino", "Fano", "Senigallia", "Civitanova",
		"San Benedetto", "Giulianova", "Vasto", "Sulmona", "Avezzano", "Rieti", "Orvieto", "Todi",
		"Spoleto", "Assisi", "Foligno", "Citta Castello", "Gubbio", "Jesi", "Fabriano", "Ostuni",
		"Gallipoli", "Otranto", "Tropea", "Paola", "Scalea", "Castrovillari", "Rossano", "Corigliano",
		"Sibari", "Policoro", "Metaponto", "Bernalda", "Pisticci", "Ferrandina", "Gravina", "Altamura",
		"Molfetta", "Bitonto", "Trani", "Bisceglie", "Monopoli", "Fasano", "Martina", "Francavilla",
		"Mesagne", "Copertino", "Nardo", "Galatina", "Maglie", "Tricase", "Santa Cesarea", "Leuca",
	},
	.German = {
		"Berlin", "Hamburg", "Munchen", "Koln", "Frankfurt", "Stuttgart", "Dusseldorf", "Leipzig",
		"Dortmund", "Essen", "Bremen", "Dresden", "Hannover", "Nurnberg", "Duisburg", "Bochum",
		"Wuppertal", "Bielefeld", "Bonn", "Munster", "Karlsruhe", "Mannheim", "Augsburg", "Wiesbaden",
		"Gelsenkirchen", "Monchengladbach", "Braunschweig", "Kiel", "Chemnitz", "Aachen", "Halle", "Magdeburg",
		"Freiburg", "Krefeld", "Lubeck", "Oberhausen", "Erfurt", "Mainz", "Rostock", "Kassel",
		"Hagen", "Saarbrucken", "Hamm", "Potsdam", "Ludwigshafen", "Oldenburg", "Mulheim", "Osnabruck",
		"Leverkusen", "Heidelberg", "Solingen", "Darmstadt", "Herne", "Neuss", "Regensburg", "Paderborn",
		"Wurzburg", "Ingolstadt", "Wolfsburg", "Ulm", "Gottingen", "Offenbach", "Reutlingen", "Heilbronn",
		"Pforzheim", "Trier", "Jena", "Gera", "Cottbus", "Erlangen", "Siegen", "Hildesheim",
		"Salzgitter", "Kaiserslautern", "Gutersloh", "Schwerin", "Flensburg", "Kempten", "Passau", "Landshut",
		"Rosenheim", "Bamberg", "Bayreuth", "Hof", "Coburg", "Weimar", "Eisenach", "Nordhausen",
		"Dessau", "Wittenberg", "Halberstadt", "Quedlinburg", "Stendal", "Neuruppin", "Brandenburg", "Gorlitz",
		"Bautzen", "Zittau", "Meissen", "Riesa", "Freiberg", "Annaberg", "Plauen", "Zwickau",
		"Altenburg", "Greiz", "Rudolstadt", "Sonneberg", "Meiningen", "Fulda", "Bad Hersfeld", "Marburg",
		"Giessen", "Wetzlar", "Limburg", "Montabaur", "Koblenz", "Andernach", "Neuwied", "Remagen",
		"Euskirchen", "Duren", "Julich", "Heinsberg", "Viersen", "Kempen", "Wesel", "Kleve",
		"Emmerich", "Bocholt", "Borken", "Ahaus", "Coesfeld", "Steinfurt", "Rheine", "Lingen",
		"Meppen", "Cloppenburg", "Vechta", "Aurich", "Leer", "Wilhelmshaven", "Cuxhaven", "Bremerhaven",
		"Stade", "Buxtehude", "Luneburg", "Uelzen", "Celle", "Nienburg", "Verden", "Rotenburg",
		"Buchholz", "Winsen", "Hameln", "Detmold", "Minden", "Herford", "Lippstadt", "Soest",
		"Unna", "Iserlohn", "Lunen", "Marl", "Dorsten", "Gladbeck", "Bottrop", "Wien",
		"Graz", "Linz", "Salzburg", "Innsbruck", "Klagenfurt", "Villach", "Wels", "Steyr",
		"Leoben", "Wiener Neustadt", "Sankt Polten", "Dornbirn", "Bregenz", "Feldkirch", "Klosterneuburg", "Baden",
		"Krems", "Amstetten", "Kapfenberg", "Traun", "Braunau", "Bad Ischl", "Hallstatt", "Zell am See",
		"Kufstein", "Schwaz", "Hall", "Imst", "Landeck", "Reutte", "Lienz", "Spittal",
		"Wolfsberg", "Judenburg", "Knittelfeld", "Eisenerz", "Mariazell", "Bruck", "Murzzuschlag", "Hartberg",
		"Gleisdorf", "Weiz", "Leibnitz", "Deutschlandsberg", "Voitsberg", "Kitzbuhel", "Telfs", "Bludenz",
		"Zurich", "Basel", "Bern", "Luzern", "Winterthur", "Sankt Gallen", "Chur", "Schaffhausen",
		"Thun", "Koniz",
	},
	.Dutch = {
		"Amsterdam", "Rotterdam", "Den Haag", "Utrecht", "Eindhoven", "Groningen", "Tilburg", "Almere",
		"Breda", "Nijmegen", "Apeldoorn", "Haarlem", "Arnhem", "Enschede", "Amersfoort", "Zaanstad",
		"Den Bosch", "Zwolle", "Leiden", "Maastricht", "Dordrecht", "Ede", "Leeuwarden", "Alkmaar",
		"Delft", "Deventer", "Venlo", "Hilversum", "Heerlen", "Hengelo", "Amstelveen", "Roosendaal",
		"Purmerend", "Oss", "Schiedam", "Spijkenisse", "Helmond", "Vlaardingen", "Almelo", "Gouda",
		"Zaandam", "Lelystad", "Hoorn", "Velsen", "Bergen op Zoom", "Capelle", "Veenendaal", "Katwijk",
		"Zeist", "Nieuwegein", "Barneveld", "Hardenberg", "Doetinchem", "Kerkrade", "Kampen", "Weert",
		"Woerden", "Sittard", "Heerhugowaard", "Rijswijk", "Middelburg", "Emmen", "Hoogeveen", "Assen",
		"Drachten", "Sneek", "Harlingen", "Dokkum", "Franeker", "Bolsward", "Workum", "Stavoren",
		"Lemmer", "Heerenveen", "Terschelling", "Vlieland", "Texel", "Den Helder", "Schagen", "Enkhuizen",
		"Medemblik", "Edam", "Volendam", "Monnickendam", "Marken", "Naarden", "Bussum", "Huizen",
		"Blaricum", "Laren", "Baarn", "Driebergen", "Doorn", "Wageningen", "Rhenen",
		"Culemborg", "Tiel", "Zutphen", "Doesburg", "Bronkhorst", "Steenderen", "Aalten", "Winterswijk",
		"Groenlo", "Lichtenvoorde", "Borculo", "Eibergen", "Haaksbergen", "Oldenzaal", "Ootmarsum", "Rijssen",
		"Holten", "Raalte", "Ommen", "Coevorden", "Klazienaveen", "Ter Apel", "Winschoten", "Delfzijl",
		"Appingedam", "Veendam", "Stadskanaal", "Roden", "Zuidhorn", "Leek", "Marum", "Grootegast",
		"Antwerpen", "Gent", "Brugge", "Leuven", "Mechelen", "Hasselt", "Kortrijk", "Oostende",
		"Genk", "Sint-Niklaas", "Roeselare", "Turnhout", "Dendermonde", "Beveren", "Lokeren", "Vilvoorde",
		"Aalst", "Tienen", "Diest", "Lier", "Herentals", "Geel", "Mol", "Beringen",
		"Tongeren", "Waregem", "Ieper", "Poperinge", "Veurne", "Nieuwpoort", "Blankenberge", "Knokke",
		"De Panne",
	},
	.Nordic = {
		"Stockholm", "Goteborg", "Malmo", "Uppsala", "Vasteras", "Orebro", "Linkoping", "Helsingborg",
		"Jonkoping", "Norrkoping", "Lund", "Umea", "Gavle", "Boras", "Sodertalje", "Karlstad",
		"Vaxjo", "Halmstad", "Lulea", "Ostersund", "Trollhattan", "Falun", "Kalmar", "Karlskrona",
		"Kristianstad", "Skelleftea", "Uddevalla", "Varberg", "Nykoping", "Visby", "Ystad", "Trelleborg",
		"Landskrona", "Harnosand", "Sundsvall", "Kiruna", "Pitea", "Boden", "Gallivare", "Mora",
		"Bollnas", "Hudiksvall", "Oskarshamn", "Vimmerby", "Eksjo", "Vetlanda", "Nassjo", "Tranas",
		"Motala", "Lidkoping", "Mariestad", "Skovde", "Alingsas", "Kungelf", "Vanersborg", "Amal",
		"Arvika", "Karlskoga", "Kumla", "Hallsberg", "Katrineholm", "Flen", "Strangnas", "Enkoping",
		"Balsta", "Sigtuna", "Norrtalje", "Vaxholm", "Nynashamn", "Soderhamn", "Sollentuna", "Solna",
		"Sundbyberg", "Danderyd", "Taby", "Vallentuna", "Akersberga", "Gustavsberg", "Nacka", "Tyreso",
		"Haninge", "Huddinge", "Botkyrka", "Jarfalla", "Kungsangen", "Knivsta", "Tierp", "Osthammar",
		"Norberg", "Fagersta", "Sala", "Koping", "Arboga", "Lindesberg", "Nora", "Hallefors",
		"Oslo", "Bergen", "Trondheim", "Stavanger", "Drammen", "Fredrikstad", "Kristiansand", "Sandnes",
		"Tromso", "Sarpsborg", "Skien", "Alesund", "Sandefjord", "Haugesund", "Tonsberg", "Moss",
		"Porsgrunn", "Bodo", "Arendal", "Hamar", "Larvik", "Halden", "Lillehammer", "Molde",
		"Harstad", "Gjovik", "Horten", "Kongsberg", "Rana", "Notodden", "Steinkjer", "Narvik",
		"Alta", "Kirkenes", "Hammerfest", "Vardo", "Vadso", "Honningsvag", "Sortland", "Svolvaer",
		"Leknes", "Stamsund", "Fauske", "Mosjoen", "Bronnoysund", "Sandnessjoen", "Nesna", "Ornes",
		"Rognan", "Evenes", "Bjerkvik", "Setermoen", "Finnsnes", "Lyngseidet", "Olderdalen", "Skjervoy",
		"Storslett", "Burfjord", "Kautokeino", "Karasjok", "Lakselv", "Berlevag", "Batsfjord", "Tana",
		"Kobenhavn", "Aarhus", "Odense", "Aalborg", "Esbjerg", "Randers", "Kolding", "Horsens",
		"Vejle", "Roskilde", "Herning", "Silkeborg", "Naestved", "Fredericia", "Viborg", "Koge",
		"Holstebro", "Taastrup", "Slagelse", "Hillerod", "Sonderborg", "Svendborg", "Hjorring", "Frederikshavn",
		"Norresundby", "Ringsted", "Haderslev", "Skive", "Nykobing", "Kalundborg", "Frederikssund", "Helsingor",
		"Hornbaek", "Gilleleje", "Hundested", "Skagen", "Hirtshals", "Thisted", "Struer", "Lemvig",
		"Ringkobing", "Skjern", "Tarm", "Varde", "Ribe", "Tonder", "Aabenraa",
		"Padborg", "Krusa", "Ronne", "Nexo", "Hasle", "Svaneke", "Gudhjem", "Allinge",
		"Sandvig", "Marstal", "Aeroskobing", "Faaborg", "Assens", "Middelfart", "Bogense", "Kerteminde",
		"Nyborg", "Rudkobing", "Maribo", "Nakskov", "Sakskobing", "Stege", "Praesto", "Vordingborg",
		"Stubbekobing", "Nysted", "Rodby", "Reykjavik", "Kopavogur", "Hafnarfjordur", "Akureyri", "Gardabaer",
		"Mosfellsbaer", "Akranes", "Selfoss", "Keflavik", "Njardvik", "Isafjordur", "Vestmannaeyjar", "Egilsstadir",
		"Husavik", "Saudarkrokur", "Borgarnes", "Stykkisholmur", "Olafsvik", "Grundarfjordur", "Holmavik", "Blonduos",
		"Siglufjordur", "Dalvik", "Hvammstangi", "Varmahlid", "Hofn", "Neskaupstadur", "Eskifjordur", "Reydarfjordur",
		"Faskrudsfjordur", "Stodvarfjordur", "Djupivogur", "Vik", "Kirkjubaejarklaustur", "Hveragerdi", "Thorlakshofn", "Eyrarbakki",
		"Stokkseyri", "Laugarvatn", "Fludir", "Hella", "Hvolsvollur", "Skogar", "Myrdal", "Grindavik",
		"Sandgerdi", "Gardur", "Vogar", "Alftanes", "Seltjarnarnes",
	},
	.English = {
		"London", "Manchester", "Birmingham", "Liverpool", "Leeds", "Sheffield", "Bristol", "Newcastle",
		"Nottingham", "Leicester", "Southampton", "Portsmouth", "Brighton", "Plymouth", "Reading", "Derby",
		"Stoke", "Wolverhampton", "Coventry", "Sunderland", "Preston", "Norwich", "Oxford", "Cambridge",
		"York", "Bath", "Exeter", "Gloucester", "Worcester", "Chester", "Durham", "Lancaster",
		"Carlisle", "Ipswich", "Colchester", "Chelmsford", "Canterbury", "Dover", "Hastings", "Eastbourne",
		"Worthing", "Bournemouth", "Poole", "Salisbury", "Winchester", "Guildford", "Woking", "Slough",
		"Watford", "Luton", "Bedford", "Milton Keynes", "Northampton", "Peterborough", "Lincoln", "Hull",
		"Grimsby", "Scarborough", "Whitby", "Harrogate", "Wakefield", "Huddersfield", "Halifax", "Bradford",
		"Keighley", "Skipton", "Kendal", "Barrow", "Blackpool", "Bolton", "Wigan", "Warrington",
		"Widnes", "Runcorn", "Crewe", "Macclesfield", "Stockport", "Oldham", "Rochdale", "Burnley",
		"Blackburn", "Accrington", "Bury", "Salford", "Wrexham", "Shrewsbury", "Telford", "Stafford",
		"Lichfield", "Tamworth", "Nuneaton", "Rugby", "Warwick", "Stratford", "Evesham", "Hereford",
		"Ludlow", "Kidderminster", "Redditch", "Bromsgrove", "Dudley", "Walsall", "Cannock", "Burton",
		"Newark", "Mansfield", "Chesterfield", "Retford", "Worksop", "Doncaster", "Barnsley", "Rotherham",
		"Scunthorpe", "Goole", "Beverley", "Bridlington", "Filey", "Malton", "Thirsk", "Northallerton",
		"Richmond", "Ripon", "Otley", "Ilkley", "Settle", "Hawes", "Appleby", "Penrith",
		"Whitehaven", "Workington", "Maryport", "Keswick", "Boston", "Providence", "Hartford", "New Haven",
		"Springfield", "Albany", "Buffalo", "Rochester", "Syracuse", "Utica", "Schenectady", "Troy",
		"Yonkers", "Trenton", "Camden", "Wilmington", "Baltimore", "Annapolis", "Norfolk", "Raleigh",
		"Charlotte", "Greensboro", "Asheville", "Savannah", "Atlanta", "Augusta", "Columbia", "Greenville",
		"Knoxville", "Nashville", "Memphis", "Chattanooga", "Louisville", "Lexington", "Cincinnati", "Columbus",
		"Cleveland", "Dayton", "Akron", "Canton", "Youngstown", "Pittsburgh", "Erie", "Harrisburg",
		"Allentown", "Scranton", "Wilkes", "Philadelphia", "Atlantic", "Concord", "Portland", "Bangor",
		"Burlington", "Montpelier", "Salem", "Eugene", "Tacoma", "Olympia", "Spokane", "Boise",
		"Cheyenne", "Denver", "Boulder", "Pueblo", "Omaha", "Topeka", "Wichita", "Tulsa",
		"Oklahoma", "Dallas", "Austin", "Houston", "Galveston", "San Antonio", "El Paso", "Albuquerque",
		"Santa Fe", "Phoenix", "Tucson", "Flagstaff", "Sacramento", "Fresno", "Oakland", "Berkeley",
		"Stockton", "Modesto", "Monterey", "San Diego", "Anaheim", "Riverside", "Pasadena", "Bakersfield",
		"Reno", "Carson", "Provo", "Ogden", "Butte", "Billings", "Fargo", "Bismarck",
		"Pierre", "Rapid", "Sioux", "Des Moines", "Madison", "Milwaukee", "Green Bay", "Duluth",
		"Minneapolis", "Detroit", "Lansing", "Flint", "Grand Rapids", "Kalamazoo", "Indianapolis", "Fort Wayne",
		"Gary", "Chicago", "Peoria", "Rockford", "St Louis", "Kansas City", "Little Rock", "Jackson",
		"Montgomery", "Mobile", "Pensacola", "Tallahassee", "Orlando", "Tampa", "Miami", "West Palm",
		"Fort Lauderdale", "Sydney", "Melbourne", "Brisbane", "Perth", "Adelaide", "Hobart", "Darwin",
		"Canberra", "Wollongong", "Geelong", "Ballarat", "Bendigo", "Toowoomba", "Cairns", "Townsville",
		"Mackay", "Rockhampton", "Bundaberg", "Gladstone", "Launceston", "Devonport", "Burnie", "Dubbo",
		"Wagga", "Albury", "Orange", "Bathurst", "Goulburn", "Lismore", "Coffs", "Armidale",
		"Broken Hill", "Kalgoorlie", "Toronto", "Ottawa", "Calgary", "Edmonton", "Winnipeg", "Lethbridge",
		"Victoria", "Regina", "Saskatoon", "Hamilton", "Kitchener", "Windsor", "Oshawa", "Barrie",
		"Sudbury", "Kingston", "Guelph", "Brampton", "Mississauga", "Surrey", "Burnaby", "Oakville",
		"St Johns", "Charlottetown", "Fredericton", "Moncton", "Truro", "Auckland", "Wellington", "Christchurch",
		"Dunedin", "Tauranga", "Napier", "Nelson", "Rotorua", "Whangarei", "Invercargill", "Palmerston",
		"Queenstown", "Dublin", "Cork", "Galway", "Limerick", "Waterford", "Drogheda", "Dundalk",
		"Sligo", "Wexford", "Kilkenny", "Ennis", "Tralee", "Athlone", "Carlow", "Navan",
		"Clonmel",
	},
}

// Invented kingdom names, curated per language so they read like the towns
// they rule. They are chosen in a fixed order rather than rolled randomly.
KINGDOM_NAMES := [TownCulture][]string {
	.Spanish = {
		"Valdoria", "Castelmar", "Alboran", "Solaria", "Monteverde", "Corvalan", "Estrellamar", "Villanova",
		"Santoro", "Rioverde", "Almenara", "Cordera", "Terramar", "Salvatierra", "Lunaria", "Auroria",
	},
	.Portuguese = {
		"Lusitania", "Portomar", "Serramar", "Alvorada", "Costeira", "Monteluz", "Aureliana", "Rivadouro",
		"Pedraverde", "Oceanica", "Bravante", "Lumar", "Ferrola", "Douramar", "Estreluz", "Cintramar",
	},
	.French = {
		"Valmont", "Beauclair", "Rivefort", "Montlune", "Clairval", "Aurelac", "Belleterre", "Rocheval",
		"Fontanelle", "Verdange", "Lumiers", "Sauveterre", "Grandval", "Coteclair", "Marveil", "Chantemer",
	},
	.Italian = {
		"Valterna", "Montefiore", "Aurentia", "Marvella", "Serenova", "Castelverde", "Rivaureo", "Lunamare",
		"Bellacosta", "Fioravalle", "Terralba", "Ventimare", "Auremonte", "Velletria", "Corviana", "Altavela",
	},
	.German = {
		"Falkenmark", "Waldhain", "Ehrental", "Nordhain", "Silbermark", "Rabenfels", "Lindenau", "Wolkenhain",
		"Adlerberg", "Morgenfels", "Nachtwald", "Hohenhain", "Falkenau", "Drachenfels", "Steinmark", "Ehrenfels",
	},
	.Dutch = {
		"Zonneveld", "Maanbrug", "Vondelrijk", "Hazenhorst", "Duinmark", "Vaandelburg", "Lindenhof", "Nevelwaard",
		"Stormvliet", "Goudhaven", "Vlierbeek", "Zandrijk", "Wolkenwaard", "Waterhof", "Bakenstein", "Morgenweide",
	},
	.Nordic = {
		"Nordhavn", "Fjellheim", "Solgard", "Vintervik", "Skogheim", "Stjernholm", "Isfjord", "Helligdal",
		"Ravnholm", "Stormnes", "Lysgard", "Morkfjell", "Snoholt", "Bjornvik", "Eikeheim", "Vargskog",
	},
	.English = {
		"Evenfall", "Highreach", "Stonebrook", "Ravenmoor", "Windmere", "Goldhollow", "Ashvale", "Thornwick",
		"Oldcastle", "Fairholm", "Westmere", "Brightwater", "Greystone", "Silverdale", "Wolfden", "Kingsbridge",
	},
}

// Syllable inventories used only if a pool is ever exhausted, or to invent a
// coherent fallback name. The first part is capitalized.
KINGDOM_ROOTS := [TownCulture][]string {
	.Spanish = {"Val", "Cor", "Mon", "Sal", "Al", "Cas", "Tor", "Bel", "Mar", "Nav", "Sol", "Ver", "Ara", "Fue", "Gra", "Oli"},
	.Portuguese = {"Lus", "Por", "Ser", "Alv", "Cos", "Mon", "Aur", "Riv", "Ped", "Oce", "Bra", "Lum", "Fer", "Dou", "Est", "Cin"},
	.French = {"Val", "Beau", "Rive", "Mont", "Clair", "Aur", "Belle", "Roche", "Font", "Verd", "Lum", "Sauve", "Grand", "Cote", "Mar", "Chan"},
	.Italian = {"Val", "Monte", "Aur", "Mar", "Seren", "Castel", "Riv", "Luna", "Bella", "Fior", "Terra", "Venti", "Aure", "Velle", "Corvi", "Alta"},
	.German = {"Falken", "Wald", "Ehre", "Nord", "Silber", "Raben", "Linden", "Wolken", "Adler", "Morgen", "Nacht", "Hohen", "Falken", "Drachen", "Stein", "Ehren"},
	.Dutch = {"Zonne", "Maan", "Vondel", "Hazen", "Duin", "Vaandel", "Linden", "Nevel", "Storm", "Goud", "Vlier", "Zand", "Wolken", "Water", "Baken", "Morgen"},
	.Nordic = {"Nord", "Fjell", "Sol", "Vinter", "Skog", "Stjern", "Is", "Hellig", "Ravn", "Storm", "Lys", "Mork", "Sno", "Bjorn", "Eike", "Varg"},
	.English = {"Even", "High", "Stone", "Raven", "Wind", "Gold", "Ash", "Thorn", "Old", "Fair", "West", "Bright", "Grey", "Silver", "Wolf", "Kings"},
}

KINGDOM_ENDINGS := [TownCulture][]string {
	.Spanish = {"dor", "terra", "mira", "vista", "rena", "luna", "marga", "quera", "tania", "bria", "cosa", "seo", "nal", "vela", "raya", "miel"},
	.Portuguese = {"mar", "terra", "luz", "vale", "douro", "inha", "eira", "alva", "ora", "ante", "ela", "ouro", "ino", "ada", "esa", "ura"},
	.French = {"mont", "clair", "fort", "lune", "val", "lac", "terre", "ange", "iers", "veil", "temer", "beau", "rive", "cour", "neau", "vigne"},
	.Italian = {"terna", "fiore", "entia", "vella", "nova", "verde", "ureo", "mare", "costa", "valle", "alba", "tri", "monte", "tria", "ana", "vela"},
	.German = {"mark", "hain", "tal", "berg", "fels", "au", "wald", "burg", "brunn", "rot", "stein", "grund", "heim", "horst", "feld", "eck"},
	.Dutch = {"veld", "brug", "rijk", "horst", "mark", "burg", "hof", "waard", "vliet", "haven", "beek", "zand", "stein", "weide", "hoek", "baan"},
	.Nordic = {"havn", "heim", "gard", "vik", "holm", "fjord", "dal", "nes", "fjell", "holt", "skog", "berg", "strand", "oy", "land", "voll"},
	.English = {"fall", "reach", "brook", "moor", "mere", "hollow", "vale", "wick", "castle", "holm", "water", "stone", "dale", "den", "bridge", "field"},
}

// Town names are rolled from the kingdom's language pool. Names already used
// anywhere in the match are skipped, so every town is unique.
NameTownAssign :: proc(w: ^World, kingdomSlot, townSlot: int) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY ||
		townSlot < 0 || townSlot >= TOWN_CAPACITY {
		return
	}

	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	culture := w.kingdoms[kingdomSlot].culture
	pool := TOWN_NAMES[culture]
	if len(pool) == 0 {
		NameTownFallback(w, kingdomSlot, townSlot)
		return
	}

	roll := WorldNoiseHash(
		town.x*73856093 ~ town.y*19349663,
		townSlot*83492791,
		w.seed ~ u64(kingdomSlot)*0x9E3779B97F4A7C15,
	)
	start := int(roll*f32(len(pool)))
	for offset in 0..<len(pool) {
		index := (start+offset)%len(pool)
		if w.usedTownName[culture][index] do continue
		candidate := pool[index]
		w.usedTownName[culture][index] = true
		if !NameTownTaken(w, candidate) {
			NameSet(&town.name, candidate)
			return
		}
	}

	NameTownFallback(w, kingdomSlot, townSlot)
}

// Composes a name from the culture's syllables. Used only as a last resort;
// the probe still guarantees that no existing town gets a duplicate name.
NameTownFallback :: proc(w: ^World, kingdomSlot, townSlot: int) {
	culture := w.kingdoms[kingdomSlot].culture
	roots := KINGDOM_ROOTS[culture]
	endings := KINGDOM_ENDINGS[culture]
	if len(roots) == 0 || len(endings) == 0 do return

	town := &w.kingdoms[kingdomSlot].towns[townSlot]
	buffer: Name
	for attempt in 0..<256 {
		rootRoll := WorldNoiseHash(town.x+attempt*17, town.y, w.seed ~ u64(kingdomSlot+1)*7919)
		endingRoll := WorldNoiseHash(townSlot+attempt, town.x ~ town.y, w.seed ~ u64(kingdomSlot+1)*104729)
		root := roots[int(rootRoll*f32(len(roots)))%len(roots)]
		ending := endings[int(endingRoll*f32(len(endings)))%len(endings)]

		length := 0
		for i in 0..<len(root) {
			buffer[length] = root[i]
			length += 1
		}
		for i in 0..<len(ending) {
			if length >= NAME_LENGTH-1 do break
			buffer[length] = ending[i]
			length += 1
		}
		candidate := string(buffer[:length])
		if !NameTownTaken(w, candidate) {
			NameSet(&town.name, candidate)
			return
		}
	}
}

// The kingdom name is curated per language and selected in slot order, so it
// is coherent with the town names and is not a random roll.
NameKingdomAssign :: proc(w: ^World, kingdomSlot: int) {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY do return
	culture := w.kingdoms[kingdomSlot].culture
	pool := KINGDOM_NAMES[culture]
	if len(pool) == 0 do return

	start := kingdomSlot%len(pool)
	for offset in 0..<len(pool) {
		candidate := pool[(start+offset)%len(pool)]
		if !NameKingdomTaken(w, candidate, kingdomSlot) {
			NameSet(&w.kingdoms[kingdomSlot].name, candidate)
			return
		}
	}

	roots := KINGDOM_ROOTS[culture]
	endings := KINGDOM_ENDINGS[culture]
	if len(roots) == 0 || len(endings) == 0 do return
	buffer: Name
	for attempt in 0..<256 {
		root := roots[(kingdomSlot+attempt)%len(roots)]
		ending := endings[(kingdomSlot*3+attempt)%len(endings)]
		length := 0
		for i in 0..<len(root) {
			buffer[length] = root[i]
			length += 1
		}
		for i in 0..<len(ending) {
			if length >= NAME_LENGTH-1 do break
			buffer[length] = ending[i]
			length += 1
		}
		candidate := string(buffer[:length])
		if !NameKingdomTaken(w, candidate, kingdomSlot) {
			NameSet(&w.kingdoms[kingdomSlot].name, candidate)
			return
		}
	}
}

NameKingdomCulture :: proc(w: ^World, kingdomSlot: int) -> TownCulture {
	count := len(TownCulture)
	if count <= 0 do return .Spanish
	base := int(w.seed%u64(count))
	return TownCulture((base+kingdomSlot)%count)
}

NameSet :: proc(name: ^Name, value: string) {
	for i in 0..<NAME_LENGTH do name[i] = 0
	length := min(len(value), NAME_LENGTH-1)
	copy(name[:length], value[:length])
}

// A fused town's absorbed hall keeps the old town's identity: "Old <Town>".
NameDistrictAssign :: proc(name: ^Name, townName: ^Name) {
	for i in 0..<NAME_LENGTH do name[i] = 0
	prefix := "Old "
	length := 0
	for i in 0..<len(prefix) {
		name[length] = prefix[i]
		length += 1
	}
	for i in 0..<NAME_LENGTH-1 {
		if townName[i] == 0 do break
		if length >= NAME_LENGTH-1 do break
		name[length] = townName[i]
		length += 1
	}
}

NameEqual :: proc(name: ^Name, value: string) -> bool {
	length := len(value)
	if length >= NAME_LENGTH do return false
	for i in 0..<length {
		if name[i] != value[i] do return false
	}
	return name[length] == 0
}

NameTownTaken :: proc(w: ^World, value: string) -> bool {
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if !w.kingdomUsed[kingdomSlot] do continue
		for townSlot in 0..<TOWN_CAPACITY {
			if !w.kingdoms[kingdomSlot].townUsed[townSlot] do continue
			if NameEqual(&w.kingdoms[kingdomSlot].towns[townSlot].name, value) do return true
		}
	}
	return false
}

NameKingdomTaken :: proc(w: ^World, value: string, ignoreKingdom: int) -> bool {
	for kingdomSlot in 0..<KINGDOMS_CAPACITY {
		if kingdomSlot == ignoreKingdom || !w.kingdomUsed[kingdomSlot] do continue
		if NameEqual(&w.kingdoms[kingdomSlot].name, value) do return true
	}
	return false
}

NameKingdomCString :: proc(w: ^World, kingdomSlot: int) -> cstring {
	if kingdomSlot < 0 || kingdomSlot >= KINGDOMS_CAPACITY || !w.kingdomUsed[kingdomSlot] {
		return "Unknown"
	}
	return cstring(&w.kingdoms[kingdomSlot].name[0])
}

NameTownCString :: proc(w: ^World, kingdomSlot, townSlot: int) -> cstring {
	if !WorldTownExists(w, kingdomSlot, townSlot) do return "Unknown"
	return cstring(&w.kingdoms[kingdomSlot].towns[townSlot].name[0])
}
