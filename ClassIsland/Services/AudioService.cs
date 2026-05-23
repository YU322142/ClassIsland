using System;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using ClassIsland.Core;
using ClassIsland.Core.Abstractions.Services;
using Microsoft.Extensions.Logging;
using SoundFlow.Abstracts;
using SoundFlow.Abstracts.Devices;
using SoundFlow.Backends.MiniAudio;
using SoundFlow.Components;
using SoundFlow.Enums;
using SoundFlow.Providers;
using SoundFlow.Structs;

namespace ClassIsland.Services;

public class AudioService(ILogger<AudioService> logger) : IAudioService
{
    // 【修改点1】：用 try-catch 包裹 MiniAudioEngine 初始化，允许为 null
    private readonly AudioEngine? _audioEngine = InitAudioEngine();
    private ILogger<AudioService> Logger { get; } = logger;

    private RefCounted<AudioPlaybackDevice>? _sharedAudioPlaybackDevice;
    private object _audioPlaybackDeviceInitializeLock = new();

    private static AudioEngine? InitAudioEngine()
    {
        try { return Task.Run(() => new MiniAudioEngine()).Result; }
        catch (Exception ex)
        {
            Console.WriteLine($"[AudioService] Audio engine init failed (non-fatal): {ex.InnerException?.Message ?? ex.Message}");
            return null;
        }
    }

    // 【修改点2】：寻找 Linux 系统自带的音频播放器
    private static string? FindSystemPlayer()
    {
        foreach (var player in new[] { "ffplay", "paplay", "aplay" })
        {
            try
            {
                var p = Process.Start(new ProcessStartInfo { FileName = "which", Arguments = player, RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true });
                p?.WaitForExit(1000);
                if (p?.ExitCode == 0) return player;
            }
            catch { }
        }
        return null;
    }

    public AudioEngine AudioEngine
    {
        get
        {
            if (_audioEngine == null) throw new PlatformNotSupportedException("当前平台不支持 SoundFlow 原生音频引擎。");
            if (OperatingSystem.IsWindows() && Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA)
            {
                throw new InvalidOperationException(
                    "出于线程安全考虑，禁止在非 MTA 线程上调用 AudioEngine。请在 MTA 线程上调用 AudioEngine。详细请见 https://github.com/ClassIsland/ClassIsland/issues/1333#issuecomment-3505591836");
            }
            return _audioEngine;
        }
    }

    public AudioPlaybackDevice? TryInitializeDefaultPlaybackDevice() =>
        TryInitializeDefaultPlaybackDeviceAsync().Result;

    public Task<AudioPlaybackDevice?> TryInitializeDefaultPlaybackDeviceAsync() => 
        Task.Run(TryInitializeDefaultPlaybackDeviceInternal);

    public Task<RefCounted<AudioPlaybackDevice>.Lease?> TryInitializeDefaultPlaybackDeviceSafeAsync() => Task.Run(() =>
    {
        lock (_audioPlaybackDeviceInitializeLock)
        {
            if (_sharedAudioPlaybackDevice?.IsValueDisposed == false)
            {
                var lease = _sharedAudioPlaybackDevice.Rent();
                Logger.LogDebug("使用了缓存的音频设备 {} (Id={})", lease.Value.Info?.Name, lease.Value.Info?.Id);
                return lease;
            }

            if (TryInitializeDefaultPlaybackDeviceInternal() is not { } device)
            {
                return null;
            }
            _sharedAudioPlaybackDevice = new RefCounted<AudioPlaybackDevice>(device);
            var lease2 = _sharedAudioPlaybackDevice.Rent();
            _sharedAudioPlaybackDevice.Dispose();
            return lease2;
        }
    });

    private AudioPlaybackDevice? TryInitializeDefaultPlaybackDeviceInternal()
    {
        try
        {
            if (_audioEngine == null) return null; // 【修改点3】：拦截空引擎

            var deviceInfo = _audioEngine.PlaybackDevices.FirstOrDefault(x => x.IsDefault);
            if (deviceInfo == default)
            {
                Logger.LogDebug("找不到可用的音频设备");
                return null;
            }

            Logger.LogDebug("初始化音频设备 {} (Id={})", deviceInfo.Name, deviceInfo.Id);
            var device = _audioEngine.InitializePlaybackDevice(deviceInfo, IAudioService.DefaultAudioFormat);
            device.MasterMixer.Volume = 1.0f;
            device.Start();
            return device;
        }
        catch (Exception ex)
        {
            Logger.LogError(ex, "初始化音频设备失败");
            return null;
        }
        
    }

    public Task PlayAudioAsync(Stream audio, float volume, CancellationToken? cancellationToken = null) => Task.Run(async () =>
    {
        cancellationToken ??= CancellationToken.None;

        // 【修改点4】：Linux 后备系统播放逻辑
        if (_audioEngine == null)
        {
            await PlayStreamViaSystemAsync(audio, volume);
            return;
        }

        using var audioStream = audio;
        using var lease = await TryInitializeDefaultPlaybackDeviceSafeAsync();
        if (lease == null)
        {
            return;
        }

        var device = lease.Value;
        using var player = new SoundPlayer(AudioEngine, IAudioService.DefaultAudioFormat,
            new StreamDataProvider(AudioEngine, IAudioService.DefaultAudioFormat, audio));
        player.Volume = volume;
        Logger.LogDebug("开始播放音频 {}", audio.GetHashCode());
        device.MasterMixer.AddComponent(player);
        var tcs = new TaskCompletionSource<bool>();

        player.PlaybackEnded += OnPlayerOnPlaybackEnded;
        cancellationToken.Value.Register(() =>
        {
            Logger.LogDebug("取消播放音频 {}", audio.GetHashCode());
            tcs.TrySetResult(false);
        });
        player.Play();
        tcs.Task.Wait();  // 不要在此处 await，否则会导致设备停止过程阻塞，无法完成播放流程。
        Logger.LogDebug("结束播放音频 {}", audio.GetHashCode());
        player.PlaybackEnded -= OnPlayerOnPlaybackEnded;

        return;

        void OnPlayerOnPlaybackEnded(object? sender, EventArgs args)
        {
            tcs.TrySetResult(true);
        }
    });

    // 【修改点5】：新增的 Stream 后备播放方法
    private async Task PlayStreamViaSystemAsync(Stream audio, float volume)
    {
        var playerName = FindSystemPlayer();
        if (playerName == null) { Logger.LogWarning("找不到系统音频播放器，无法播放声音。"); return; }
        
        var tempFile = Path.Combine(Path.GetTempPath(), $"ci_audio_{Guid.NewGuid():N}.wav");
        try
        {
            using (var fs = File.Create(tempFile)) { await audio.CopyToAsync(fs); }
            await RunPlayerAsync(playerName, tempFile, volume);
        }
        catch (Exception ex) { Logger.LogWarning("系统音频播放失败: {Msg}", ex.Message); }
        finally { try { File.Delete(tempFile); } catch { } }
    }

    public async Task PlayAudioAsync(string filePath, float volume, CancellationToken? cancellationToken = null)
    {
        // 【修改点6】：新增的本地文件后备播放逻辑
        if (_audioEngine == null && !RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var playerName = FindSystemPlayer();
            if (playerName == null) { Logger.LogWarning("找不到系统音频播放器，无法播放声音。"); return; }
            await RunPlayerAsync(playerName, filePath, volume);
            return;
        }

        using var audio = File.OpenRead(filePath);
        await PlayAudioAsync(audio, volume, cancellationToken);
    }

    // 【修改点7】：执行系统播放器（完全忽略 CancellationToken 以防被 TTS 模块错误掐断）
    private async Task RunPlayerAsync(string playerName, string filePath, float volume)
    {
        var args = playerName switch
        {
            "ffplay" => $"-nodisp -autoexit -volume {(int)(volume * 100)} \"{filePath}\"",
            "paplay" => $"--volume {(int)(volume * 65536)} \"{filePath}\"",
            _ => $"\"{filePath}\""
        };
        
        Logger.LogDebug("使用 {Player} 播放音频: {File}", playerName, filePath);
        
        var psi = new ProcessStartInfo
        {
            FileName = playerName, 
            Arguments = args,
            UseShellExecute = false, 
            CreateNoWindow = true,
            RedirectStandardOutput = true, 
            RedirectStandardError = true
        };
        
        using var process = Process.Start(psi);
        if (process != null) 
        {
            await process.WaitForExitAsync(); // 不传入 cancellationToken，强制等它播完
        }
    }

    public void Dispose()
    {
        _audioEngine?.Dispose();
        GC.SuppressFinalize(this);
    }
}
