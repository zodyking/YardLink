import SwiftUI
import UIKit

/// First launch. Yard Link is self-hosted, so before anyone can sign in the
/// app has to learn which employer's server to talk to.
struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scanning = false
    @State private var typing = false
    @State private var address = ""

    var body: some View {
        ZStack {
            Brand.mist.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                        .padding(.top, 40)
                        .accessibilityLabel("Yard Link")

                    VStack(spacing: 8) {
                        Text("Connect to Your Employer")
                            .font(.title2.weight(.bold))
                            .foregroundColor(Brand.navy)
                            .multilineTextAlignment(.center)
                        Text("Scan the QR code your dispatcher shows you. It tells Yard Link which company server to use.")
                            .font(.body)
                            .foregroundColor(Brand.muted)
                            .multilineTextAlignment(.center)
                    }

                    if let error = model.connectError {
                        ErrorBanner(message: error)
                    }

                    Card {
                        Button {
                            model.connectError = nil
                            scanning = true
                        } label: {
                            Label(model.isConnecting ? "Connecting…" : "Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isConnecting)

                        if typing {
                            TextField("yard.yourcompany.com", text: $address)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.go)
                                .onSubmit(connectTyped)
                                .accessibilityLabel("Server address")
                            Button("Connect", action: connectTyped)
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(model.isConnecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
                            Button("Enter the address instead") { typing = true }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }

                    Text("Your dispatcher finds the code in Yard Link on the web, under Settings.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $scanning) {
            ScannerSheet { text in
                scanning = false
                model.handleConnectText(text)
            }
        }
    }

    private func connectTyped() {
        model.handleConnectText(address)
    }
}

private struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var cameraProblem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let cameraProblem {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                        Text(cameraProblem)
                            .multilineTextAlignment(.center)
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: settings)
                                .font(.headline)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(32)
                } else {
                    QRScannerView(onScan: onScan) { problem in
                        cameraProblem = problem
                    }
                    .ignoresSafeArea()

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Brand.sky, lineWidth: 4)
                        .frame(width: 250, height: 250)
                        .accessibilityHidden(true)

                    VStack {
                        Spacer()
                        Text("Point the camera at the code")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.bottom, 48)
                    }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
