#include <sourcemod>
#include <sdktools>
#include <multicolors>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.3"
#define WHITELIST_FILE "configs/whitelist.txt"
#define LOG_FILE "logs/ip_chat_blocker.log"

ArrayList g_hWhitelistIPs;
ConVar g_cvMuteDuration;
ConVar g_cvSpamThreshold;
ConVar g_cvSpamWarn;
ConVar g_cvSpamGagDuration;

StringMap g_hSpamCount;

public Plugin myinfo =
{
    name = "IP Chat Mute & Spam Control",
    author = "+SyntX",
    description = "Mutes players if they share a non-whitelisted IP in chat or spam.",
    version = PLUGIN_VERSION,
    url = "https://steamcommunity.com/id/SyntX34 &7 https://github.com/SyntX34"
};

public void OnPluginStart()
{
    // Hook chat commands
    RegConsoleCmd("say", Command_Say);
    RegConsoleCmd("say_team", Command_Say);

    g_hWhitelistIPs = new ArrayList(16);
    g_hSpamCount = new StringMap();

    // Create ConVars
    g_cvMuteDuration = CreateConVar("sm_ip_chat_blocker_duration", "30", "Duration (in minutes) to mute players who share an IP. Set to 0 for permanent mute.", FCVAR_NONE, true, 0.0);
    g_cvSpamThreshold = CreateConVar("sm_spam_threshold", "5", "Number of messages in a short period to consider as spam.", FCVAR_NONE, true, 1.0);
    g_cvSpamWarn = CreateConVar("sm_spam_warn", "1", "Warn players before gagging them for spam. (1 = Enabled, 0 = Disabled)", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvSpamGagDuration = CreateConVar("sm_spam_gag_duration", "10", "Initial gag duration (in minutes) for spammers.", FCVAR_NONE, true, 1.0);

    // AutoExec config
    AutoExecConfig(true, "ip_chat_blocker");

    LoadIPLists();
}

void LoadIPLists()
{
    g_hWhitelistIPs.Clear();
    
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/whitelist.txt");

    if (!FileExists(path))
    {
        LogError("Whitelist file does not exist: %s", path);
        return;
    }

    File file = OpenFile(path, "r");
    if (!file)
    {
        LogError("Failed to open whitelist file: %s", path);
        return;
    }

    LogMessage("Successfully opened whitelist file: %s", path);

    char line[64];
    while (file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (strlen(line) > 0)
        {
            g_hWhitelistIPs.PushString(line);
        }
    }
    delete file;

    LogMessage("Loaded %d whitelisted IPs.", g_hWhitelistIPs.Length);
}



public Action Command_Say(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Continue;

    char text[192];
    GetCmdArgString(text, sizeof(text));

    // Check for IP sharing
    if (ContainsIP(text))
    {
        char ips[16][16];
        int ipCount = ExtractIPs(text, ips, sizeof(ips));

        for (int i = 0; i < ipCount; i++)
        {
            char ip[16];
            strcopy(ip, sizeof(ip), ips[i]);

            if (!IsIPWhitelisted(ip))
            {
                int duration = g_cvMuteDuration.IntValue;
                GagPlayer(client, duration, "Advertising");
                LogToFile(LOG_FILE, "Player %N (IP: %s) was gagged for %d minutes for sharing a non-whitelisted IP.", client, ip, duration);
                CPrintToChat(client, "{green}[IP Chat Blocker] {white}You are gagged for %s. Reason: {red}Advertising", FormatDuration(duration));
                return Plugin_Handled;
            }
        }
    }

    // Check for spam
    if (DetectSpam(client))
    {
        HandleSpam(client);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

bool ContainsIP(const char[] text)
{
    return StrContains(text, ".") != -1;
}

int ExtractIPs(const char[] text, char[][] ips, int maxIps)
{
    int ipCount = 0;
    char buffer[192];
    strcopy(buffer, sizeof(buffer), text);

    char parts[32][16];
    int partCount = ExplodeString(buffer, " ", parts, sizeof(parts), sizeof(parts[]));

    for (int i = 0; i < partCount; i++)
    {
        if (IsValidIP(parts[i]))
        {
            strcopy(ips[ipCount], 16, parts[i]);
            ipCount++;

            if (ipCount >= maxIps)
                break;
        }
    }

    return ipCount;
}

bool IsValidIP(const char[] ip)
{
    int octets[4];
    return (StringToIP(ip, octets) == 1);
}

int StringToIP(const char[] ip, int octets[4])
{
    char parts[4][4];

    int count = ExplodeString(ip, ".", parts, 4, sizeof(parts[]));

    if (count != 4)
    {
        return 0;
    }

    for (int i = 0; i < 4; i++)
    {
        octets[i] = StringToInt(parts[i]);
    }

    return 1;
}

bool IsIPWhitelisted(const char[] ip)
{
    return (g_hWhitelistIPs.FindString(ip) != -1);
}

bool DetectSpam(int client)
{
    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    int count = 0;
    if (!g_hSpamCount.GetValue(steamId, count))
    {
        count = 0;
    }

    count++;
    g_hSpamCount.SetValue(steamId, count);

    if (count >= g_cvSpamThreshold.IntValue)
    {
        g_hSpamCount.Remove(steamId);
        return true;
    }

    CreateTimer(10.0, ResetSpamCount, GetClientUserId(client));
    return false;
}

public Action ResetSpamCount(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0)
    {
        char steamId[32];
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
        g_hSpamCount.Remove(steamId);
    }
    return Plugin_Stop;
}

void HandleSpam(int client)
{
    if (g_cvSpamWarn.BoolValue)
    {
        CPrintToChat(client, "{green}[Spam Control] {white}Warning: Do not spam in chat.");
    }
    else
    {
        int duration = g_cvSpamGagDuration.IntValue;
        GagPlayer(client, duration, "Spamming");
        LogToFile(LOG_FILE, "Player %N was gagged for %d minutes for spamming.", client, duration);
        CPrintToChat(client, "{green}[Spam Control] {white}You have been gagged for %s. Reason: {red}Spamming", FormatDuration(duration));
    }
}

void GagPlayer(int client, int duration, const char[] reason)
{
    char command[64];
    Format(command, sizeof(command), "sm_gag #%d %d %s", GetClientUserId(client), duration, reason);
    ServerCommand(command);
}

char[] FormatDuration(int duration)
{
    char buffer[64];
    if (duration < 60)
    {
        Format(buffer, sizeof(buffer), "%d seconds", duration);
    }
    else if (duration < 3600)
    {
        Format(buffer, sizeof(buffer), "%d minutes", duration / 60);
    }
    else
    {
        Format(buffer, sizeof(buffer), "%d hours", duration / 3600);
    }
    return buffer;
}