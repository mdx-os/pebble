// into: Packages/PebbleKit/Sources/PebbleCore
// expect: encryption or certificate pinning needs a fresh export review
import Security

func fixtureSeal(_ key: SecKey, _ data: CFData) -> CFData? {
    SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, data, nil)
}
