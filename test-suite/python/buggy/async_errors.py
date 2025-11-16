import asyncio

async def fetch_user(uid):
    resp = await asyncio.sleep(0.1)
    return resp

async def refresh_dashboard():
    await fetch_user('abc')
    task = asyncio.create_task(fetch_user('lazy'))
    # fire-and-forget: never awaited or cancelled
    return task

async def bootstrap():
    await refresh_dashboard()
    await fetch_user('xyz')

if __name__ == '__main__':
    asyncio.run(bootstrap())
