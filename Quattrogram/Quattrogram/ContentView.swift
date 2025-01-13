import SwiftUI
import AVFoundation
import MediaPlayer

struct ContentView: View {
    @StateObject private var viewModel = SongListViewModel()
    @StateObject private var audioManager = AudioPlayerManager()
    @State private var searchText: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack {
                    TextField("Поиск...", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding()

                    if viewModel.isLoading {
                        ProgressView("Загрузка песен...")
                    } else if viewModel.errorMessage != nil {
                        Text(viewModel.errorMessage!)
                            .foregroundColor(.red)
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.songs) { song in
                                NavigationLink(destination: PlayerView(audioManager: audioManager, song: song, allSongs: viewModel.songs)) {
                                    SongCard(
                                        title: song.name,
                                        artist: song.artist,
                                        coverImageURL: song.coverURL
                                    )
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Главная")
            .onAppear {
                viewModel.fetchSongs()
            }
            .onChange(of: searchText) { newValue in
                viewModel.searchSongs(query: newValue)
            }
        }
    }
}

struct SongCard: View {
    let title: String
    let artist: String
    let coverImageURL: URL?

    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: coverImageURL) { image in
                image.resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .cornerRadius(10)
            } placeholder: {
                ProgressView()
                    .frame(width: 60, height: 60)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(artist)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
        }
        .cornerRadius(12)
    }
}

class AudioPlayerManager: ObservableObject {
    @Published var currentSong: Song?
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isRepeatEnabled: Bool = false
    @Published var songLyrics: String?

    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var songsList: [Song] = []
    private var currentIndex: Int = 0

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    func fetchSongLyrics(songId: String) {
            // Реализуем запрос к API для получения текста песни.
            let url = URL(string: "https://api.qgram.ru/")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            let body = [
                "action": "gettext",
                "song_id": songId
            ]
            
            let jsonData = try? JSONSerialization.data(withJSONObject: body)
            request.httpBody = jsonData
            
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self, let data = data, error == nil else {
                    print("Error fetching lyrics: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }
                
                // Обрабатываем ответ и обновляем текст песни
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    DispatchQueue.main.async {
                        self.songLyrics = text
                    }
                }
            }.resume()
        }

    func play(song: Song, songs: [Song]) {
        self.songsList = songs
        if currentSong?.id == song.id {
            resume()
            return
        }

        resetPlayer()
        currentSong = song
        currentIndex = songs.firstIndex { $0.id == song.id } ?? 0

        guard let url = song.audioURL else { return }
        audioPlayer = AVPlayer(url: url)

        if let currentItem = audioPlayer?.currentItem {
            duration = currentItem.asset.duration.seconds
        }

        addPeriodicTimeObserver()
        audioPlayer?.play()
        isPlaying = true

        updateNowPlayingInfo(song: song)

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlayingInfo(song: currentSong)
    }

    func seek(to time: Double) {
        guard let player = audioPlayer else { return }
        let targetTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: targetTime)
        currentTime = time
        updateNowPlayingInfo(song: currentSong)
    }

    private func resume() {
        audioPlayer?.play()
        isPlaying = true
    }

    private func resetPlayer() {
        audioPlayer?.pause()
        if let observer = timeObserver {
            audioPlayer?.removeTimeObserver(observer)
        }
        audioPlayer = nil
        currentSong = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo(song: Song?) {
        guard let song = song else { return }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime
        ]

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    @objc func appDidEnterBackground() {
        print("App entered background")
    }

    @objc func appWillEnterForeground() {
        print("App entered foreground")
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = audioPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            if let duration = self.audioPlayer?.currentItem?.duration.seconds, duration > 0 {
                self.duration = duration
            }

            // Если время песни достигает конца и повтор включен, начинаем песню сначала
            if self.currentTime >= self.duration - 1 {
                if self.isRepeatEnabled {
                    self.seek(to: 0)  // Перематываем на начало
                    self.resume()     // Сразу начинаем воспроизведение
                } else {
                    self.nextSong()   // Переходим к следующей песне, если повтор не включен
                }
            }
        }
    }

    func toggleRepeat() {
        isRepeatEnabled.toggle()
    }

    func nextSong() {
        guard !songsList.isEmpty else { return }

        if isRepeatEnabled {
            play(song: currentSong ?? songsList[currentIndex], songs: songsList)
        } else {
            currentIndex = (currentIndex + 1) % songsList.count
            play(song: songsList[currentIndex], songs: songsList)
        }
    }
    
    func forceNextSong() {
        guard !songsList.isEmpty else { return }
        currentIndex = (currentIndex + 1) % songsList.count
        play(song: songsList[currentIndex], songs: songsList)
    }
    
    func previousSong() {
        guard !songsList.isEmpty else { return }
        
        currentIndex = (currentIndex - 1 + songsList.count) % songsList.count
        play(song: songsList[currentIndex], songs: songsList)
    }
}

struct PlayerView: View {
    @ObservedObject var audioManager: AudioPlayerManager
    @State var song: Song
    let allSongs: [Song]
    
    @State private var isModalPresented = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                AsyncImage(url: song.coverURL) { image in
                    image
                        .resizable()
                        .scaledToFill() // Масштабируем изображение так, чтобы оно заполнило область
                        .frame(width: .infinity, height: .infinity) // Устанавливаем размер области
                        .clipped() // Обрезаем изображение за пределами области
                        .cornerRadius(16) // Скругляем углы
                        .padding(24)
                } placeholder: {
                    ProgressView()
                }
                .frame(width: .infinity, height: .infinity) // Устанавливаем размер контейнера
                .padding(24)
                .cornerRadius(16) // Скругляем углы контейнера
            }


            VStack(spacing: 0) {
                Text(song.name)
                    .font(.title)
                    .bold()
                    .padding(.top, 10)

                Text(song.artist)
                    .font(.title2)
                    .foregroundColor(.gray)
            }

            HStack {
                Text(formatTime(audioManager.currentTime))
                    .font(.footnote)
                    .foregroundColor(.gray)

                Slider(value: $audioManager.currentTime, in: 0...audioManager.duration, onEditingChanged: { editing in
                    if !editing {
                        audioManager.seek(to: audioManager.currentTime)
                    }
                })
                .padding(.horizontal)

                Text(formatTime(audioManager.duration))
                    .font(.footnote)
                    .foregroundColor(.gray)
            }

            HStack {
                Button(action: audioManager.toggleRepeat) {
                    Image(systemName: audioManager.isRepeatEnabled ? "repeat.circle.fill" : "repeat.circle")
                        .font(.title)
                        .padding()
                }
                .foregroundColor(audioManager.isRepeatEnabled ? .blue : .gray)
                
                Button(action: audioManager.previousSong) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .padding()
                }

                Button(action: audioManager.togglePlayPause) {
                    Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .padding()
                }

                Button(action: audioManager.forceNextSong) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .padding()
                }
                
                // Кнопка для открытия модального окна
                Button(action: {
                    isModalPresented.toggle()
                }) {
                    Image(systemName: "textformat")
                        .font(.title)
                        .padding()
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            audioManager.play(song: song, songs: allSongs)
        }
        .onChange(of: audioManager.currentSong) { newSong in
            song = newSong ?? song
        }
        // Модальное окно
        .sheet(isPresented: $isModalPresented) {
            ModalView(audioManager: audioManager) // Передаем audioManager для актуальной песни
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct ModalView: View {
    @ObservedObject var audioManager: AudioPlayerManager

    var body: some View {
        HStack {
            VStack {
                if let currentSong = audioManager.currentSong {
                    HStack {
                        VStack {
                            Text(currentSong.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.title)
                            Text(currentSong.artist)
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer()
                        HStack {
                            Button(action: audioManager.togglePlayPause) {
                                Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.largeTitle)
                            }
                        }
                    }
                }
                
                // Отображаем текст песни в ScrollView
                if let lyrics = audioManager.songLyrics {
                    ScrollView {
                        if lyrics != "$LYRICS_OUT" {
                            Text(lyrics)
                                .font(.title3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Текст отсутсвует")
                                .foregroundColor(.gray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                    }
                } else {
                    Text("Текст песни загружается...")
                        .padding()
                }
            }
        }
        .padding()
        .onAppear {
            // Загружаем текст песни сразу при открытии модального окна
            if let songId = audioManager.currentSong?.id {
                audioManager.fetchSongLyrics(songId: songId)
            }
        }
        .onChange(of: audioManager.currentSong) { newSong in
            if let songId = newSong?.id {
                audioManager.fetchSongLyrics(songId: songId)
            }
        }
    }
}

class SongListViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let apiURL = "https://api.qgram.ru/"

    func fetchSongs() {
        sendRequest(with: ["action": "list"])
    }

    func searchSongs(query: String) {
        if query.isEmpty {
            fetchSongs() // Сброс поиска
        } else {
            sendRequest(with: ["action": "list", "search": query])
        }
    }

    private func sendRequest(with body: [String: Any]) {
        guard let url = URL(string: apiURL) else { return }

        isLoading = true
        errorMessage = nil

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isLoading = false

                if let error = error {
                    self.errorMessage = "Ошибка: \(error.localizedDescription)"
                    return
                }

                guard let data = data else {
                    self.errorMessage = "Данные не найдены."
                    return
                }

                do {
                    let result = try JSONDecoder().decode(SongListResponse.self, from: data)
                    self.songs = result.songs
                } catch {
                    self.errorMessage = "Ошибка декодирования данных: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
}

struct Song: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let artist: String

    var coverURL: URL? {
        URL(string: "https://api.qgram.ru/covers/\(id)/maxresdefault.png")
    }

    var audioURL: URL? {
        URL(string: "https://api.qgram.ru/songs/\(id).wav")
    }

    var lyricsURL: URL? {
        URL(string: "https://api.qgram.ru/")
    }

    static func == (lhs: Song, rhs: Song) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.artist == rhs.artist
    }
}

struct SongListResponse: Decodable {
    let status: String
    let songs: [Song]
}

#Preview {
    ContentView()
}
