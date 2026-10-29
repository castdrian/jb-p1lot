use std::{env, fs, path::PathBuf, process::ExitCode};

use idevice::{
    IdeviceError, IdeviceService, RsdService,
    core_device_proxy::CoreDeviceProxy,
    dvt::{remote_server::RemoteServerClient, screenshot::ScreenshotClient},
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    provider::{IdeviceProvider, UsbmuxdProvider},
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};

const LABEL: &str = "jb-p1lot";
const DEVELOPER_DISK_IMAGE: &str = "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore";

#[tokio::main]
async fn main() -> ExitCode {
    let arguments: Vec<String> = env::args().skip(1).collect();
    let result = match arguments.as_slice() {
        [command] if command == "version" => Ok(String::from(env!("CARGO_PKG_VERSION"))),
        [command] if command == "list" => list(true).await,
        [command, flag] if command == "list" && flag == "--brief" => list(false).await,
        [command, udid] if command == "mount" => mount(udid).await,
        [command, udid] if command == "unmount" => unmount(udid).await,
        [command, udid, output] if command == "screenshot" => screenshot(udid, output).await,
        _ => Err(String::from(
            "usage: jb-p1lot-idevice version | list [--brief] | mount <udid> | unmount <udid> | screenshot <udid> <output.png>",
        )),
    };
    match result {
        Ok(message) => {
            println!("{message}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn describe(error: IdeviceError) -> String {
    format!("{error:?}")
}

async fn provider(udid: &str) -> Result<UsbmuxdProvider, String> {
    let mut usbmuxd = UsbmuxdConnection::default().await.map_err(describe)?;
    let device = usbmuxd.get_device(udid).await.map_err(describe)?;
    let address = UsbmuxdAddr::from_env_var().map_err(|error| error.to_string())?;
    Ok(device.to_provider(address, LABEL))
}

async fn describe_device(
    device: UsbmuxdDevice,
    address: UsbmuxdAddr,
    details_wanted: bool,
) -> serde_json::Value {
    let connection = match device.connection_type {
        Connection::Usb => "usb",
        Connection::Network(_) => "network",
        Connection::Unknown(_) => "unknown",
    };
    let provider = device.to_provider(address, LABEL);
    let mut details = serde_json::Map::new();
    if !details_wanted {
        details.insert(String::from("udid"), serde_json::Value::from(device.udid));
        details.insert(
            String::from("connection"),
            serde_json::Value::from(connection),
        );
        return serde_json::Value::Object(details);
    }
    if let Ok(mut lockdown) = LockdownClient::connect(&provider).await {
        if let Ok(pairing) = provider.get_pairing_file().await {
            let _ = lockdown.start_session(&pairing).await;
        }
        for (key, field) in [
            ("DeviceName", "name"),
            ("ProductType", "productType"),
            ("ProductVersion", "osVersion"),
        ] {
            if let Ok(value) = lockdown.get_value(Some(key), None).await
                && let Some(text) = value.as_string() {
                    details.insert(String::from(field), serde_json::Value::from(text));
                }
        }
    }
    details.insert(String::from("udid"), serde_json::Value::from(device.udid));
    details.insert(
        String::from("connection"),
        serde_json::Value::from(connection),
    );
    serde_json::Value::Object(details)
}

fn preferred(devices: Vec<UsbmuxdDevice>) -> Vec<UsbmuxdDevice> {
    let mut chosen: Vec<UsbmuxdDevice> = Vec::new();
    for device in devices {
        let usb = matches!(device.connection_type, Connection::Usb);
        match chosen.iter().position(|known| known.udid == device.udid) {
            Some(index) if usb => chosen[index] = device,
            Some(_) => {}
            None => chosen.push(device),
        }
    }
    chosen
}

async fn list(details_wanted: bool) -> Result<String, String> {
    let mut usbmuxd = UsbmuxdConnection::default().await.map_err(describe)?;
    let devices = preferred(usbmuxd.get_devices().await.map_err(describe)?);
    let address = UsbmuxdAddr::from_env_var().map_err(|error| error.to_string())?;
    let mut lookups = tokio::task::JoinSet::new();
    for device in devices {
        lookups.spawn(describe_device(device, address.clone(), details_wanted));
    }
    let mut described = Vec::new();
    while let Some(result) = lookups.join_next().await {
        if let Ok(value) = result {
            described.push(value);
        }
    }
    serde_json::to_string(&described).map_err(|error| error.to_string())
}

async fn unique_chip_id(provider: &UsbmuxdProvider) -> Result<u64, String> {
    let mut lockdown = LockdownClient::connect(provider).await.map_err(describe)?;
    let pairing = provider.get_pairing_file().await.map_err(describe)?;
    lockdown.start_session(&pairing).await.map_err(describe)?;
    let value = lockdown
        .get_value(Some("UniqueChipID"), None)
        .await
        .map_err(describe)?;
    value
        .as_unsigned_integer()
        .ok_or_else(|| String::from("the device did not report a UniqueChipID"))
}

fn manifest_path(manifest: &plist::Dictionary, component: &str) -> Option<String> {
    manifest
        .get("BuildIdentities")?
        .as_array()?
        .first()?
        .as_dictionary()?
        .get("Manifest")?
        .as_dictionary()?
        .get(component)?
        .as_dictionary()?
        .get("Info")?
        .as_dictionary()?
        .get("Path")?
        .as_string()
        .map(String::from)
}

fn read(path: &PathBuf) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| format!("could not read {}: {error}", path.display()))
}

async fn mount(udid: &str) -> Result<String, String> {
    let provider = provider(udid).await?;
    let mut mounter = ImageMounter::connect(&provider).await.map_err(describe)?;
    let mounted = mounter.copy_devices().await.map_err(describe)?;
    if !mounted.is_empty() {
        return Ok(String::from("a developer disk image is already mounted"));
    }

    let root = PathBuf::from(DEVELOPER_DISK_IMAGE);
    let build_manifest = read(&root.join("BuildManifest.plist"))?;
    let manifest: plist::Dictionary =
        plist::from_bytes(&build_manifest).map_err(|error| error.to_string())?;
    let image_path = manifest_path(&manifest, "PersonalizedDMG")
        .ok_or_else(|| String::from("the build manifest names no personalized disk image"))?;
    let trust_cache_path = manifest_path(&manifest, "LoadableTrustCache")
        .ok_or_else(|| String::from("the build manifest names no trust cache"))?;
    let image = read(&root.join(image_path))?;
    let trust_cache = read(&root.join(trust_cache_path))?;
    let chip = unique_chip_id(&provider).await?;

    mounter
        .mount_personalized(&provider, image, trust_cache, &build_manifest, None, chip)
        .await
        .map_err(describe)?;
    Ok(String::from("mounted the developer disk image"))
}

async fn unmount(udid: &str) -> Result<String, String> {
    let provider = provider(udid).await?;
    let mut mounter = ImageMounter::connect(&provider).await.map_err(describe)?;
    mounter
        .unmount_image("/System/Developer")
        .await
        .map_err(describe)?;
    Ok(String::from("unmounted the developer disk image"))
}

async fn screenshot(udid: &str, output: &str) -> Result<String, String> {
    let provider = provider(udid).await?;
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .map_err(describe)?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy
        .create_software_tunnel()
        .map_err(describe)?
        .to_async_handle();
    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|error| error.to_string())?;
    let mut handshake = RsdHandshake::new(stream).await.map_err(describe)?;
    let mut server = RemoteServerClient::connect_rsd(&mut adapter, &mut handshake)
        .await
        .map_err(describe)?;
    let mut client = ScreenshotClient::new(&mut server).await.map_err(describe)?;
    let image = client.take_screenshot().await.map_err(describe)?;
    fs::write(output, &image).map_err(|error| format!("could not write {output}: {error}"))?;
    Ok(format!("wrote {} bytes to {output}", image.len()))
}
