#!/usr/bin/env python3
"""Probe or launch an app on a previously paired iOS device over Wi-Fi."""
import argparse
import asyncio
import socket
import sys
from contextlib import AsyncExitStack, suppress

from pymobiledevice3.lockdown import create_using_tcp
from pymobiledevice3.pair_records import get_usbmux_pairing_record
from pymobiledevice3.remote import tunnel_service
from pymobiledevice3.remote.core_device.app_service import AppServiceService
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane
from pymobiledevice3.services.heartbeat import HeartbeatService
from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService


def process_ids(value):
    """Extract process identifiers without printing unrelated device metadata."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'processIdentifier' and isinstance(item, int) and not isinstance(item, bool):
                yield int(item)
            else:
                yield from process_ids(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from process_ids(item)


async def run(args):
    addresses = await asyncio.get_running_loop().getaddrinfo(
        args.host, None, family=socket.AF_INET, type=socket.SOCK_STREAM
    )
    host = addresses[0][4][0]
    record = await get_usbmux_pairing_record(args.udid)
    if not record:
        raise RuntimeError('No system pairing record found for the requested device')

    original_userspace_flag = tunnel_service.USE_USERSPACE_TUNNEL
    try:
        async with AsyncExitStack() as stack:
            heartbeat_lock = await create_using_tcp(host, identifier=args.udid, pair_record=record, autopair=False)
            stack.push_async_callback(heartbeat_lock.close)
            if not heartbeat_lock.paired or heartbeat_lock.udid != args.udid:
                raise RuntimeError('Heartbeat connection did not authenticate the requested device')
            heartbeat = await heartbeat_lock.start_lockdown_service(HeartbeatService.SERVICE_NAME)
            stack.push_async_callback(heartbeat.close)
            first = await heartbeat.recv_plist()
            if first.get('Command') != 'Marco':
                raise RuntimeError('Unexpected heartbeat response')
            await heartbeat.send_plist({'Command': 'Polo'})

            async def beat():
                while True:
                    message = await heartbeat.recv_plist()
                    if message.get('Command') != 'Marco':
                        raise RuntimeError('Unexpected heartbeat response')
                    await heartbeat.send_plist({'Command': 'Polo'})

            task = asyncio.create_task(beat())

            async def stop_heartbeat():
                task.cancel()
                with suppress(asyncio.CancelledError, Exception):
                    await task

            stack.push_async_callback(stop_heartbeat)
            lock = await create_using_tcp(host, identifier=args.udid, pair_record=record, autopair=False)
            stack.push_async_callback(lock.close)
            if not lock.paired or lock.udid != args.udid:
                raise RuntimeError('Lockdown connection did not authenticate the requested device')
            print('authenticated=True')
            print(f'ios_version={lock.product_version}')
            mode = await lock.get_value(domain='com.apple.security.mac.amfi', key='DeveloperModeStatus')
            print(f'developer_mode={bool(mode)}')
            async with MobileImageMounterService(lock) as image_service:
                images = await image_service.copy_devices()
                mounted = any(x.get('IsMounted') and x.get('DiskImageType') in ('Developer', 'Personalized') for x in images)
            print(f'ddi_mounted={mounted}')
            tunnel_service.USE_USERSPACE_TUNNEL = True
            provider = await CoreDeviceTunnelProxy.create(lock)
            stack.push_async_callback(provider.close)
            tunnel = await stack.enter_async_context(provider.start_tcp_tunnel())
            tun = tunnel.client.tun
            tun.set_peer(tunnel.address)
            dial = await stack.enter_async_context(UserspaceDialPlane(tun, tunnel.address))
            rsd = RemoteServiceDiscoveryService((tunnel.address, tunnel.port), open_connection=dial.dial,
                                               auxiliary_metadata=tunnel.auxiliary_metadata)
            stack.push_async_callback(rsd.close)
            await rsd.connect()
            if rsd.udid != args.udid:
                raise RuntimeError('Developer connection did not match the requested device')
            print('developer_connection=True')
            if args.launch:
                async with AppServiceService(rsd) as apps:
                    result = await apps.launch_application(args.launch, kill_existing=False)
                    pids = set(process_ids(result))
                    if len(pids) != 1:
                        raise RuntimeError('Launch did not return one process identifier')
                    pid = pids.pop()
                    await asyncio.sleep(3)
                    running = pid in set(process_ids(await apps.list_processes()))
                    print(f'bundle={args.launch} pid={pid} running={running}')
                    if not running:
                        raise RuntimeError('Launched process was not present after three seconds')
            if task.done():
                task.result()
    finally:
        tunnel_service.USE_USERSPACE_TUNNEL = original_userspace_flag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True, help='UDID of an already paired device')
    parser.add_argument('--host', default='iPhone.local', help='device hostname or IPv4 address (default: iPhone.local)')
    parser.add_argument('--launch', metavar='BUNDLE_ID', help='launch an installed app and verify its process')
    parser.add_argument('--timeout', type=float, default=40, help='overall timeout in seconds (default: 40)')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    try:
        asyncio.run(asyncio.wait_for(run(args), timeout=args.timeout))
    except Exception as exc:
        print(f'error={type(exc).__name__}', file=sys.stderr)
        if isinstance(exc, RuntimeError):
            print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
