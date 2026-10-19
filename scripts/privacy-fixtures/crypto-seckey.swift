// into: Packages/PebbleKit/Sources/PebbleCore
// expect: its own encryption or certificate pinning
import Security

func fixtureSeal(_ key: SecKey, _ data: CFData) -> CFData? {
    SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, data, nil)
}
