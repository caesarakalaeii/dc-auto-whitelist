import discord
import json
from discord.ext import commands
from rcon import Client
from config import *



# Initialize bot and RCON client
bot = commands.Bot(command_prefix="!")

@bot.event
async def on_ready():
    print(f"Logged in as {bot.user.name} - {bot.user.id}")

@bot.event
async def on_message(message):
    if message.author == bot.user:
        return
    if not message.channel.id == CHANNEL_ID:
        return
    if message.content.startswith("!whitelist"):
        await handleWhiteList(message)
    if message.content.startswith("!unwhitelist"):
        await handleUnWhiteList(message)

async def handleWhiteList(message):
    # Extract discord id
        discord_id = str(message.author.id)
        splits = message.content.split()
        
        # Save to JSON
        whitelist_data = {}
        try:
            with open("whitelist.json", "r") as f:
                whitelist_data = json.load(f)
        except FileNotFoundError:
            pass

        if whitelist_data[discord_id] == True: 
            await message.channel.send(f"{message.author.mention} you are already whitelisted!")
            return

        whitelist_data[discord_id] = True
        with open("whitelist.json", "w") as f:
            json.dump(whitelist_data, f)

        # Execute RCON commands
        rcon = Client(RCON_HOST, RCON_PORT, password=RCON_PASSWORD)
        rcon.connect()
        rcon.command(f"whitelist add {splits[1]}")
        rcon.command("whitelist reload")
        rcon.close()

        await message.channel.send(f"{message.author.mention} has been whitelisted!")
        
async def handleUnWhiteList(message):
    # Extract discord id
        discord_id = str(message.author.id)
        splits = message.content.split()
        
        # Save to JSON
        whitelist_data = {}
        try:
            with open("whitelist.json", "r") as f:
                whitelist_data = json.load(f)
        except FileNotFoundError:
            pass

        if whitelist_data[discord_id] == False: 
            await message.channel.send(f"{message.author.mention} you haven't been whitelisted!")
            return

        whitelist_data[discord_id] = False
        with open("whitelist.json", "w") as f:
            json.dump(whitelist_data, f)

        # Execute RCON commands
        rcon = Client(RCON_HOST, RCON_PORT, password=RCON_PASSWORD)
        rcon.connect()
        rcon.command(f"whitelist remove {splits[1]}")
        rcon.command("whitelist reload")
        rcon.close()

        await message.channel.send(f"{message.author.mention} has been unwhitelisted!")
    
# Run the bot
bot.run(TOKEN)