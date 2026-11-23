import SwiftUI
import VisionKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = Settings.address
    @State private var apiKey = Settings.apiKey
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…ts.net", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Macin osoite")
                } footer: {
                    Text("Tailscalen osoite, jonka `tailscale serve status` näyttää.")
                }
                Section {
                    SecureField("th-jarvis-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if DataScannerViewController.isSupported {
                        Button("Lue QR-koodista") { scanning = true }
                    }
                    Button("Liitä leikepöydältä") { apiKey = UIPasteboard.general.string ?? apiKey }
                } header: {
                    Text("API-avain")
                } footer: {
                    Text("Macilla: saareke → oikea klikkaus → Jarvis → Kopioi API-avain. Avain tallennetaan Keychainiin.")
                }
            }
            .navigationTitle("Asetukset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valmis") {
                        Settings.address = address
                        Settings.apiKey = apiKey
                        dismiss()
                    }
                    .disabled(apiKey.isEmpty || URL(string: address)?.scheme == nil)
                }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    apiKey = code
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// Reads the first QR code the camera sees.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let text = code.payloadStringValue, !text.isEmpty {
                    scanner.stopScanning()
                    found(text)
                    return
                }
            }
        }
    }
}
