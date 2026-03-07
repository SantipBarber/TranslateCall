import SwiftUI

struct DeviceSectionView: View {
    @EnvironmentObject private var viewModel: AudioViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Microphone")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                Picker("Microphone", selection: $viewModel.selectedInput) {
                    if viewModel.inputDevices.isEmpty {
                        Text("No devices found").tag(Optional<AudioDevice>.none)
                    } else {
                        ForEach(viewModel.inputDevices) { device in
                            Text(device.name).tag(Optional(device))
                        }
                    }
                }
                .labelsHidden()
                .disabled(viewModel.inputDevices.isEmpty)
                .onChange(of: viewModel.selectedInput) { _, new in
                    if let device = new { viewModel.selectInput(device) }
                }
            }

            GridRow {
                Text("Output")
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)

                Picker("Output", selection: $viewModel.selectedOutput) {
                    if viewModel.outputDevices.isEmpty {
                        Text("No devices found").tag(Optional<AudioDevice>.none)
                    } else {
                        ForEach(viewModel.outputDevices) { device in
                            Text(device.name).tag(Optional(device))
                        }
                    }
                }
                .labelsHidden()
                .disabled(viewModel.outputDevices.isEmpty)
                .onChange(of: viewModel.selectedOutput) { _, new in
                    if let device = new { viewModel.selectOutput(device) }
                }
            }
        }
    }
}

#Preview {
    DeviceSectionView()
        .environmentObject(AudioViewModel.preview())
        .padding()

}
