import SwiftUI
import SwiftData

struct LiveRecordingView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @State private var autoScroll = true
    @State private var showCopilot = true
    @AppStorage("copilotEnabled") private var copilotEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            recordingHeader

            Divider()

            // Audio waveform
            AudioWaveformView(level: recordingManager.audioCaptureManager.audioLevel)
                .frame(height: 40)
                .padding(.horizontal)

            Divider()

            // Live transcript + copilot
            HStack(spacing: 0) {
                transcriptArea

                if copilotEnabled && showCopilot {
                    Divider()
                    CopilotPanelView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recording Header

    private var recordingHeader: some View {
        HStack {
            // Recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.5), radius: 4)

                Text("Recording")
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Spacer()

            // Timer
            Text(recordingManager.formattedElapsedTime)
                .font(.title2)
                .monospacedDigit()
                .fontWeight(.medium)

            Spacer()

            // Copilot panel toggle
            if copilotEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCopilot.toggle()
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.headline)
                        .foregroundStyle(showCopilot ? .purple : .secondary)
                }
                .buttonStyle(.plain)
                .help(showCopilot ? "Hide Copilot" : "Show Copilot")
                .padding(.trailing, 12)
            }

            // Stop button
            Button {
                Task {
                    await recordingManager.stopRecording()
                }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let meeting = recordingManager.currentMeeting {
                        ForEach(meeting.sortedSegments) { segment in
                            LiveSegmentRow(segment: segment)
                                .id(segment.id)
                        }
                    }

                    if !recordingManager.transcriptionEngine.currentText.isEmpty {
                        Text(recordingManager.transcriptionEngine.currentText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .id("currentText")
                    }

                    if recordingManager.currentMeeting?.segments.isEmpty == true
                        && recordingManager.transcriptionEngine.currentText.isEmpty {
                        Text("Parrot is listening...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .italic()
                            .padding(.horizontal)
                            .padding(.top, 20)
                    }
                }
                .padding()
            }
            .onChange(of: recordingManager.currentMeeting?.segments.count) {
                if autoScroll {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("currentText", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Live Segment Row

struct LiveSegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(segment.formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Audio Waveform

struct AudioWaveformView: View {
    let level: Float
    @State private var levels: [Float] = Array(repeating: 0, count: 50)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3, height: max(2, CGFloat(levels[index]) * 60))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: level) { _, newValue in
            levels.removeFirst()
            levels.append(newValue)
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}
