import Virtualization
import Dynamic

struct UnsupportedHostOSError: Error, CustomStringConvertible {
  var description: String {
    "error: host macOS version is outdated to run this virtual machine"
  }
}

#if arch(arm64)

  struct Darwin: PlatformSuspendable {
    var ecid: VZMacMachineIdentifier
    var hardwareModel: VZMacHardwareModel

    init(ecid: VZMacMachineIdentifier, hardwareModel: VZMacHardwareModel) {
      self.ecid = ecid
      self.hardwareModel = hardwareModel
    }

    // Factory method to create a Darwin platform with custom hardware descriptor (private API)
    static func withCustomHardwareDescriptor(platformVersion: UInt32, isa: UInt32) -> Darwin? {
      #if arch(arm64)
        let descriptorClass = NSClassFromString("_VZMacHardwareModelDescriptor")
        if let descriptorClass = descriptorClass {
          let descriptor = Dynamic(descriptorClass).alloc().init()
          descriptor.setPlatformVersion(platformVersion)

          // ISA can be set as integer value or via enum
          // Common values: 1 = M1, 2 = M2, 3 = M3, 4 = appleInternal4 (research/vphone)
          descriptor.setISA(isa)

          let hardwareModelClass = NSClassFromString("VZMacHardwareModel") as? NSObject.Type
          if let hardwareModelClass = hardwareModelClass {
            let hwModel = Dynamic(hardwareModelClass)._hardwareModelWith(descriptor.asObject!)
            if let hwModel = hwModel.asObject as? VZMacHardwareModel {
              return Darwin(ecid: VZMacMachineIdentifier(), hardwareModel: hwModel)
            }
          }
        }
      #endif
      return nil
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      let encodedECID = try container.decode(String.self, forKey: .ecid)
      guard let data = Data.init(base64Encoded: encodedECID) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize Data using the provided value")
      }
      guard let ecid = VZMacMachineIdentifier.init(dataRepresentation: data) else {
        throw DecodingError.dataCorruptedError(forKey: .ecid,
                                               in: container,
                                               debugDescription: "failed to initialize VZMacMachineIdentifier using the provided value")
      }
      self.ecid = ecid

      let encodedHardwareModel = try container.decode(String.self, forKey: .hardwareModel)
      guard let data = Data.init(base64Encoded: encodedHardwareModel) else {
        throw DecodingError.dataCorruptedError(forKey: .hardwareModel, in: container, debugDescription: "")
      }
      guard let hardwareModel = VZMacHardwareModel.init(dataRepresentation: data) else {
        throw UnsupportedHostOSError()
      }
      self.hardwareModel = hardwareModel
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(ecid.dataRepresentation.base64EncodedString(), forKey: .ecid)
      try container.encode(hardwareModel.dataRepresentation.base64EncodedString(), forKey: .hardwareModel)
    }

    func os() -> OS {
      .darwin
    }

    func bootLoader(nvramURL: URL) throws -> VZBootLoader {
      let bootloader = VZMacOSBootLoader()

      // Set custom ROM URL for AVPBooter (private API)
      let avpBooterPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin"
      if FileManager.default.fileExists(atPath: avpBooterPath) {
        Dynamic(bootloader)._romURL = URL(filePath: avpBooterPath)
      }

      return bootloader
    }

    func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
      if needsNestedVirtualization {
        throw RuntimeError.VMConfigurationError("macOS virtual machines do not support nested virtualization")
      }

      let result = VZMacPlatformConfiguration()

      result.machineIdentifier = ecid
      result.auxiliaryStorage = VZMacAuxiliaryStorage(url: nvramURL)

      if !hardwareModel.isSupported {
        // At the moment support of M1 chip is not yet dropped in any macOS version
        // This mean that host software is not supporting this hardware model and should be updated
        throw UnsupportedHostOSError()
      }

      result.hardwareModel = hardwareModel

      // Disable production mode for research/development (private API)
      Dynamic(result)._isProductionModeEnabled = false

      return result
    }

    func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
      let result = VZMacGraphicsDeviceConfiguration()

      if (vmConfig.display.unit ?? .point) == .point, let hostMainScreen = NSScreen.main {
        let vmScreenSize = NSSize(width: vmConfig.display.width, height: vmConfig.display.height)
        result.displays = [
          VZMacGraphicsDisplayConfiguration(for: hostMainScreen, sizeInPoints: vmScreenSize)
        ]

        return result
      }

      result.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: vmConfig.display.width,
          heightInPixels: vmConfig.display.height,
          // A reasonable guess according to Apple's documentation[1]
          // [1]: https://developer.apple.com/documentation/coregraphics/1456599-cgdisplayscreensize
          pixelsPerInch: vmConfig.display.pixelsPerInch
        )
      ]

      return result
    }

    func keyboards() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        // Mac keyboard is only supported by guests starting with macOS Ventura
        return [VZUSBKeyboardConfiguration(), VZMacKeyboardConfiguration()]
      } else {
        return [VZUSBKeyboardConfiguration()]
      }
    }

    func keyboardsSuspendable() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacKeyboardConfiguration()]
      } else {
        // fallback to the regular configuration
        return keyboards()
      }
    }

    func pointingDevices() -> [VZPointingDeviceConfiguration] {
      // Trackpad is only supported by guests starting with macOS Ventura
      [VZUSBScreenCoordinatePointingDeviceConfiguration(), VZMacTrackpadConfiguration()]
    }

    func pointingDevicesSimplified() -> [VZPointingDeviceConfiguration] {
      // Only include the USB pointing device, not the trackpad
      return [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    func pointingDevicesSuspendable() -> [VZPointingDeviceConfiguration] {
      if #available(macOS 14, *) {
        return [VZMacTrackpadConfiguration()]
      } else {
        // fallback to the regular configuration
        return pointingDevices()
      }
    }
  }

#endif
