import SwiftUI
import AVFoundation
import MediaPlayer

struct ContentView: View {
    @StateObject private var viewModel = SongListViewModel()
    @StateObject private var audioManager = AudioPlayerManager() // Добавляем сюда AudioPlayerManager

    var body: some View {
        NavigationView {
            ScrollView {
                if viewModel.isLoading {
                    ProgressView("Загрузка песен...")
                } else if viewModel.errorMessage != nil {
                    Text(viewModel.errorMessage!)
                        .foregroundColor(.red)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(viewModel.songs) { song in
                            NavigationLink(destination: PlayerView(song: song, audioManager: audioManager)) { // Передаем audioManager в PlayerView
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
            .navigationTitle("Главная")
        }
        .onAppear {
            viewModel.fetchSongs()
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
    @Published var isRepeatEnabled: Bool = false // Повтор трека

    private var audioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var songsList: [Song] = []
    private var currentIndex: Int = 0

    init() {
        // Обрабатываем переходы в фон и активность
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // Метод для начала воспроизведения
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

        // Обновляем Now Playing Info
        updateNowPlayingInfo(song: song)

        // Разрешаем фоновое воспроизведение
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // Метод для паузы и продолжения воспроизведения
    func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()

        // Обновляем Now Playing Info
        updateNowPlayingInfo(song: currentSong)
    }

    // Метод для перемотки
    func seek(to time: Double) {
        guard let player = audioPlayer else { return }
        let targetTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: targetTime)
        currentTime = time

        // Обновляем Now Playing Info
        updateNowPlayingInfo(song: currentSong)
    }

    // Метод для восстановления воспроизведения
    private func resume() {
        audioPlayer?.play()
        isPlaying = true
    }

    // Сброс плеера
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

        // Очищаем Now Playing Info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // Метод для обновления информации о треке
    private func updateNowPlayingInfo(song: Song?) {
        guard let song = song else { return }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyArtwork: MPMediaItemArtwork(boundsSize: CGSize(width: 100, height: 100)) { _ in
                return UIImage(systemName: "music.note")! // Используйте свою обложку
            }
        ]
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // Функция для обработки событий, когда приложение уходит в фон
    @objc func appDidEnterBackground() {
        // Обрабатываем сохранение состояния плеера
        print("App entered background")
    }

    // Функция для обработки событий, когда приложение возвращается в фон
    @objc func appWillEnterForeground() {
        // Восстанавливаем состояние плеера
        print("App entered foreground")
    }

    // Метод для добавления периодического таймера
    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = audioPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
            self?.updateNowPlayingInfo(song: self?.currentSong)

            if self?.currentTime == self?.duration {
                self?.nextSong()
            }
        }
    }

    // Включение/выключение повтора
    func toggleRepeat() {
        isRepeatEnabled.toggle()
    }

    // Переход к следующему треку
    func nextSong() {
        if isRepeatEnabled {
            play(song: currentSong ?? songsList[currentIndex], songs: songsList)
        } else {
            currentIndex = (currentIndex + 1) % songsList.count
            play(song: songsList[currentIndex], songs: songsList)
        }
    }

    // Переход к предыдущему треку
    func previousSong() {
        currentIndex = (currentIndex - 1 + songsList.count) % songsList.count
        play(song: songsList[currentIndex], songs: songsList)
    }
}

struct PlayerView: View {
    let song: Song
    @ObservedObject var audioManager: AudioPlayerManager

    var body: some View {
        VStack(spacing: 20) {
            AsyncImage(url: song.coverURL) { image in
                image.resizable()
                    .scaledToFit()
                    .cornerRadius(16)
            } placeholder: {
                ProgressView()
                    .frame(width: 300, height: 300)
            }

            VStack(spacing: 0) {
                Text(song.name)
                    .font(.title)
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artist)
                    .font(.title2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Button(action: audioManager.previousSong) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .padding()
                        .background(Circle().fill(Color.blue))
                }

                Button(action: audioManager.togglePlayPause) {
                    Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                        .padding()
                        .background(Circle().fill(Color.blue))
                }

                Button(action: audioManager.nextSong) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .padding()
                        .background(Circle().fill(Color.blue))
                }
            }

            Toggle("Повтор", isOn: $audioManager.isRepeatEnabled)
                .padding()

            Spacer()
        }
        .padding()
        .onAppear {
            audioManager.play(song: song, songs: [song])
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

class SongListViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func fetchSongs() {
        guard let url = URL(string: "https://api.qgram.ru/") else { return }

        isLoading = true
        errorMessage = nil

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["action": "list"]
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

struct Song: Identifiable, Decodable {
    let id: String
    let name: String
    let artist: String

    var coverURL: URL? {
        URL(string: "https://api.qgram.ru/covers/\(id)/maxresdefault.png")
    }

    var audioURL: URL? {
        URL(string: "https://api.qgram.ru/songs/\(id).wav")
    }
}

struct SongListResponse: Decodable {
    let status: String
    let songs: [Song]
}

#Preview {
    ContentView()
}
 
