#!/sbin/sh

AKHOME="$(dirname "$(readlink -f "$0")")"

properties() { '
kernel.string=KernelSU by KernelSU Developers
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

。 "$AKHOME/tools/ak3-core.sh"

detect_key_press() {
    local prompt="$1" up_option="$2" down_option="$3"
    ui_print "-> ${prompt}"
    ui_print "   音量上键: ${up_option}"
    ui_print "   音量下键: ${down_option}"
    ui_print "   10秒后将自动选择默认选项"
    
    key_output=$(timeout 10 getevent -qlc 1 2>/dev/null)
    
    if [ -n "$key_output" ]; then
        key=$(echo "$key_output" | awk '{print $3}')
        case "$key" in
            "KEY_VOLUMEUP")
                ui_print "-> 用户选择: ${up_option}"
                return 0
                ;;
            "KEY_VOLUMEDOWN")
                ui_print "-> 用户选择: ${down_option}"
                return 1
                ;;
        esac
    fi
    
    ui_print "-> 超时未选择，使用默认选项"
    return 2
}

show_header() {
    ui_print "-> 开始执行刷机脚本... ✨"
    ui_print "power by"
    ui_print "—————Frost_Bai"
}

check_magisk_environment() {
    if [ -d /data/adb/magisk ] && [ -f "$AKHOME/magisk_patched" ]; then
        ui_print "注意Magisk/Alpha直接刷入可能有奇怪的问题，建议完全卸载后安装"
        
        detect_key_press "检测到 Magisk/Alpha 环境，是否继续？" "继续安装" "退出安装"
        case $? in
            0) ui_print "-> 继续安装（风险自负）⚠️" ;;
            1) abort "-> 用户选择退出安装（检测到 Magisk/Alpha 环境）❌" ;;
            2) ui_print "-> 无操作，继续安装（风险自负）⚠️" ;;
        esac
    fi
}

clean_conflicts() {
    ui_print "-> 正在尝试删除冲突部分..."

    set -- \
        "/data/adb/modules/zygisk_shamiko|卸载Zygisk-Shamiko模块" \
        "/data/adb/shamiko|清理Shamiko残留文件" \
        "/data/adb/magisk.db|移除Magisk数据库" 

    for target in "$@"; do
        [ -z "$target" ] && continue
        
        path=$(echo "$target" | cut -d '|' -f 1)
        message=$(echo "$target" | cut -d '|' -f 2)

        if [ -e "$path" ]; then
            ui_print "▸ 正在处理: $message"
            target_name=$(basename "$path")

            if rm -rf "$path" 2>/dev/null; then
                ui_print "✅ 清理成功: $target_name"
                case "$target_name" in
                    "zygisk_shamiko"|"shamiko")
                        ui_print "   ▸ 已卸载shamiko，susfs和它不兼容也不需要"
                        ;;
                    "magisk.db")
                        ui_print "   ▸ 注意: Magisk配置可能需要手动清除"
                        ;;
                esac
            else
                ui_print "⚠️ 清理失败: $target_name (可能需要手动删除)"
            fi
        else
            ui_print "ℹ️ 未发现: $(basename "$path")"
        fi
    done

    ui_print "✔️ 冲突模块处理完成"
}

check_kernel_version() {
    ui_print "----------------------------------------"
    ui_print "-> 检测设备信息..."
    ui_print "-> 设备信息："
    ui_print "   设备名称: $(getprop ro.product.device)"
    ui_print "   设备型号: $(getprop ro.product.model)"
    ui_print "   Android 版本: $(getprop ro.build.version.release)"
    ui_print "   内核版本: $(uname -r)"
    
    kernel_version=$(cat /proc/version | awk -F '[- ]' '{print $3}')
    case $kernel_version in
        5.1*|6.1*) ksu_supported=true ;;
        *) ksu_supported=false ;;
    esac
    
    ui_print "-> 检测到内核版本: $kernel_version"
    ui_print "-> ksu_supported: $ksu_supported"
    $ksu_supported || abort "-> 非 GKI 设备，终止刷入 ❌"
}

process_boot_partition() {
    if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
        ui_print "-> 设备使用 init_boot 分区，开始拆解... 🛠️"
        split_boot
    else
        ui_print "-> 设备使用 boot 分区，开始拆解... 🛠️"
        dump_boot
    fi
}

apply_kpm_patch() {
    KPM_PATCH_SUCCESS=false
    KPM_RETRIES=0
    MAX_RETRIES=3

    while [ "$KPM_PATCH_SUCCESS" = false ] && [ "$KPM_RETRIES" -lt "$MAX_RETRIES" ]; do
        KPM_RETRIES=$((KPM_RETRIES + 1))
        ui_print "-----------------------------------------"
        ui_print "-> KPM 补丁尝试次数: $KPM_RETRIES / $MAX_RETRIES"
        ui_print "没有需求不建议开启"
        
        detect_key_press "是否应用 KPM 补丁？" "启用补丁😄" "跳过补丁😆"
        case $? in
            0) SKIP_PATCH=0 ;;
            1|2) SKIP_PATCH=1 ;;
        esac

        IMG_SRC="$AKHOME/Image"
        PATCH_BIN="$AKHOME/patch_android"

        if [ "$SKIP_PATCH" -eq 0 ]; then
            ui_print "-> 开始应用 KPM 补丁... 🩹"
            [ ! -f "$PATCH_BIN" ] && abort "ERROR：找不到补丁工具 $PATCH_BIN ❌"
            
            TMPDIR="/data/local/tmp/kpm_patch_$(date +%Y%m%d_%H%M%S)_$$"
            mkdir -p "$TMPDIR" || abort "ERROR：创建临时目录失败 ❌"
            cp "$IMG_SRC" "$TMPDIR/" || abort "ERROR：复制 Image 失败 ❌"
            cp "$PATCH_BIN" "$TMPDIR/" || abort "ERROR：复制 patch_android 失败 ❌"
            chmod +x "$TMPDIR/patch_android"
            cd "$TMPDIR" || abort "ERROR: 切换到临时目录失败 ❌"

            ui_print "-> 执行 patch_android..."
            ./patch_android
            PATCH_EXIT_CODE=$?

            ui_print "-> patch_android 执行返回码: $PATCH_EXIT_CODE"

            if [ "$PATCH_EXIT_CODE" -eq 0 ]; then
                [ ! -f "oImage" ] && abort "ERROR：oImage 未生成，补丁可能失败 ❌"
                mv oImage Image
                cp Image "$split_img/kernel" || abort "ERROR：复制补丁后 Image 到 AnyKernel3 临时目录失败 ❌"
                ui_print "-> KPM 补丁应用完成 🎉"
                rm -rf "$TMPDIR"
                KPM_PATCH_SUCCESS=true
            else
                ui_print "ERROR：patch_android 执行失败 (返回码: $PATCH_EXIT_CODE) ❌"
                rm -rf "$TMPDIR"
            fi
        else
            ui_print "-> 跳过补丁，使用原始内核镜像"
            cp "$IMG_SRC" "$split_img/kernel" || abort "ERROR：复制原始 Image 到 AnyKernel3 临时目录失败 ❌"
            KPM_PATCH_SUCCESS=true
        fi
    done

    [ "$KPM_PATCH_SUCCESS" = false ] && abort "ERROR：KPM 补丁尝试 $MAX_RETRIES 次后仍然失败，中止刷入 ❌"
}

write_boot_partition() {
    ui_print "-> 写回引导分区... ✍️"
    if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
        flash_boot || abort "ERROR：flash_boot 失败 ❌"
    else
        write_boot || abort "ERROR：write_boot 失败 ❌"
    fi
    ui_print "-> 引导分区写回完成 ✅"
}

main() {
    show_header
    check_magisk_environment
    clean_conflicts
    check_kernel_version
    process_boot_partition
    apply_kpm_patch
    write_boot_partition
    
    sleep 1
    ui_print "----------------------------------------"
    ui_print "内核构建By:KFzZ"
    ui_print "刷入成功，请重启设备以应用更改 🎉"
    ui_print "----------------------------------------"
    exit 0
}

main
