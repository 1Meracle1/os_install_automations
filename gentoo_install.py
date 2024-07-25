import os
from subprocess import call
import subprocess
import json
import http.client
from urllib.parse import urlparse, urljoin
from html.parser import HTMLParser
import urllib.request
from datetime import datetime

disk_name = ''
boot_partition = ''
root_partition = ''


def run(command, throw_on_failure=False, custom_error_message=""):
    result = call(command)
    if result != 0 and throw_on_failure:
        if custom_error_message != "":
            raise Exception(f"{custom_error_message}, result: '{result}', command: '{command}'")
        else:
            raise Exception(f"Failed to run command, result: '{result}', command: '{command}'")


########################################################################################################################
def setup_partitions():
    print("Setting up partitions")
    print("Disks layout before partitioning:")
    run("lsblk")
    global disk_name
    disk_name = input("Specify disk name to partition").strip()
    if disk_name == "":
        raise Exception("Disk name should not be empty")

    # Start the parted utility
    parted_process = subprocess.Popen(
        ['sudo', 'parted', disk_name],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    # Define the commands to send to parted
    commands = [
        'mklabel gpt',  # Create a new GPT partition table
        'mkpart boot fat32 0% 2GB',  # Create boot partition
        'mkpart root btrfs 2GB 100%',  # Create root partition
        'set 1 boot on',
        'p',  # Print the partition table
        'q'  # Exit parted
    ]
    # Send the commands to parted
    output, error = parted_process.communicate(input='\n'.join(commands) + '\n')

    print("Output:\n", output)
    if error:
        raise Exception(f"Error:\n{error}")

    print("Disks layout after partitioning:")
    run("lsblk")
    global boot_partition, root_partition
    result = subprocess.run("lsblk --json", shell=True, check=True, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    lsblk_output = json.loads(result.stdout)
    for device in lsblk_output["blockdevices"]:
        if "children" in device:
            partitions = device["children"]
            if partitions[0]["size"] > partitions[1]["size"]:
                boot_partition = "/dev/" + partitions[0]["name"]
                root_partition = "/dev/" + partitions[1]["name"]
            else:
                boot_partition = "/dev/" + partitions[1]["name"]
                root_partition = "/dev/" + partitions[0]["name"]

    if boot_partition == "" or root_partition == "":
        raise Exception("Failed to populate boot/root partition from lsblk output")


def root_encryption():
    print("Setting up root encryption")
    run(f"cryptsetup luksFormat -s256 -c aes-xts-plain64 {root_partition}")
    run(f"cryptsetup luksOpen {root_partition} cryptroot")


def filesystem_creation():
    run(f"mkfs.vfat -F 32 {boot_partition}")
    run("mkfs.btrfs -L BTROOT /dev/mapper/cryptroot")


def mounting_and_subvolume_creation():
    run("mkdir /mnt/root")
    run("mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag /dev/mapper/cryptroot /mnt/root")
    run("btrfs subvolume create /mnt/root/activeroot")
    run("btrfs subvolume create /mnt/root/home")
    run(
        "mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo")
    run("mkdir /mnt/gentoo/home")
    run(
        "mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home")
    run("mkdir /mnt/gentoo/boot")
    run("mkdir /mnt/gentoo/efi")
    run(f"mount {boot_partition} /mnt/gentoo/boot")
    run(f"mount {boot_partition} /mnt/gentoo/efi")


########################################################################################################################
def fetch_web_page(url):
    """
    Fetch the HTML content of the web page.

    Args:
        url (str): The URL of the web page.

    Returns:
        str: The HTML content of the web page.
    """
    parsed_url = urlparse(url)
    conn = http.client.HTTPSConnection(parsed_url.netloc)
    conn.request("GET", parsed_url.path)
    response = conn.getresponse()
    if response.status in (301, 302):
        # Handle redirects
        redirect_url = response.getheader('Location')
        if redirect_url:
            # If the redirect URL is relative, join it with the base URL
            redirect_url = urljoin(url, redirect_url)
            print(f"Redirecting to {redirect_url}")
            return fetch_web_page(redirect_url)
    if response.status != 200:
        raise Exception(f"Failed to fetch web page: {response.status} {response.reason}")
    html_content = response.read().decode()
    conn.close()
    return html_content, url


def parse_timestamp(timestamp):
    datetime_format = "%Y%m%dT%H%M%SZ"
    return datetime.strptime(timestamp, datetime_format)


def is_valid_timestamp(timestamp):
    try:
        parse_timestamp(timestamp)
        return True
    except ValueError:
        return False


def find_latest_timestamp(timestamps):
    """
    Find the latest timestamp from a list of timestamp strings.

    Args:
        timestamps (list of str): A list of timestamp strings.

    Returns:
        str: The latest timestamp string.
    """
    # Parse all timestamps into datetime objects
    parsed_timestamps = [parse_timestamp(ts) for ts in timestamps]

    # Find the latest datetime object
    latest_timestamp = max(parsed_timestamps)

    # Convert the latest datetime object back to the string format
    datetime_format = "%Y%m%dT%H%M%SZ"
    return latest_timestamp.strftime(datetime_format)


class FoldersHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.file_links = []

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            for attr in attrs:
                if attr[0] == 'href':
                    href = attr[1]
                    if href[-1] == '/':
                        href = href[:-1]
                    if is_valid_timestamp(href):
                        self.file_links.append(href)


class FilesHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.file_links = []

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            for attr in attrs:
                if attr[0] == 'href':
                    href = attr[1]
                    if href.startswith('stage3-amd64-hardened-openrc') and (
                            href.endswith('.tar.xz') or href.endswith('.asc')):
                        self.file_links.append(href)


def download_file(url, save_path):
    """
    Download the file from the given URL.

    Args:
        url (str): The URL of the file to download.
        save_path (str): The local path to save the downloaded file.
    """
    urllib.request.urlretrieve(url, save_path)
    print(f"File downloaded: {save_path}")


def verify_stage3_file(files):
    for file in files:
        if file.endswith('.asc'):
            run(f"gpg --verify ./{file}", True, f"File failed verification: '{file}'")
            run(f'rm -rf {file}', True)
            return file[:-4]
    raise Exception("Haven't found files to verify")


def time_sync_and_stage3_download():
    call("chronyd -q")

    url = 'https://distfiles.gentoo.org/releases/amd64/autobuilds'
    # url = 'https://gentoo.osuosl.org/releases/amd64/autobuilds/'
    html_content, url = fetch_web_page(url)
    parser = FoldersHTMLParser()
    parser.feed(html_content)
    file_links = parser.file_links
    if not file_links:
        raise Exception("No relevant folders with stage3 archives found.")
    latest_timestamp = find_latest_timestamp(file_links)
    folder_url = urljoin(url, latest_timestamp)
    html_content, folder_url = fetch_web_page(folder_url)
    parser = FilesHTMLParser()
    parser.feed(html_content)
    if len(parser.file_links) == 0:
        raise Exception("No stage3 archives found.")

    for file in parser.file_links:
        download_path = url + '/' + latest_timestamp + '/' + file
        save_path = os.path.join(os.getcwd(), os.path.basename(file))
        print(f"Downloading\n\tfrom: '{download_path}'\n\tto: '{save_path}'")
        download_file(download_path, save_path)

    stage3_archive_file = verify_stage3_file(parser.file_links)
    run(f'mv ./{stage3_archive_file} /mnt/gentoo', True)
    run('cd /mnt/gentoo')
    print('Unpacking the stage3 archive')
    run(f'tar xpvf ./{stage3_archive_file} --xattrs-include="*.*" --numeric-owner')
    run(f'rm -rf ./{stage3_archive_file}')


########################################################################################################################
if __name__ == '__main__':
    setup_partitions()
    root_encryption()
    filesystem_creation()
    mounting_and_subvolume_creation()
    time_sync_and_stage3_download()
