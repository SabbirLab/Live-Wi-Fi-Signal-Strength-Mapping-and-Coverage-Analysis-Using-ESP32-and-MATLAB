function app = WiFiHeatmapLive_Animated()
% WIFIHEATMAPLIVE Collect RSSI grid points with the ESP32 and watch the
% heatmap build up live, in one window.
%
% This combines WiFiHeatmapCollector (serial connection + grid recording)
% with the WiFiHeatmapAnalyzer maths (IDW surface, root-finding threshold
% boundary, trapezoidal coverage), and redraws the heatmap every time you
% record, remove, or clear a point, or change a setting.
%
%   Usage:  app = WiFiHeatmapLive_Animated;
%
% ANIMATIONS (tick 'Animate heatmap' above the plot to switch them on/off):
%   - Morph: whenever a point is recorded, removed or loaded, the surface
%     smoothly flows from the old map to the new one (first map blooms up).
%   - Router rings: white signal rings radiate out from the router star.
%   - Pulse: the newest recorded point (yellow dot) breathes in and out.
%   - 'Rotate 3D view': slowly spins the 3D surface.
% If the window ever crashes and leaves the timer running, type:
%   delete(timerfindall)
%
% Needs on the MATLAB path: bisection_method.m, falseposition_method.m,
% newtonraphson_method.m, secant_method.m (same folder is fine).
%
% Workflow: Connect -> type your X/Y -> wait for the buffer to read
% 15 / 15 -> Record Point -> the map updates. The green X on the map
% shows the X/Y you have typed ("you are here"). In Honest mode, gray
% areas are too far from any real measurement to be trusted, so you can
% see the gray shrink as you cover the room.
%
% R2014a notes: legacy figure/uicontrol, serial(), single quotes only,
% text() uses the 'Parent' property, ishandle() instead of isvalid(), and
% the plot axes are rebuilt on every redraw (avoids the legacy colorbar
% "Bad handle" problem).

    % ---- Fixed internal defaults ----
    RES_LIVE  = 45;    % grid resolution (kept modest so redraws stay instant)
    IDW_POWER = 3.5;   % inverse-distance-weighting power
    MAX_DIST  = 1.2;   % Honest mode: cells farther than this from any point are gaps (m)
    BUF_N     = 15;    % fresh samples averaged per recorded point
    MORPH_FRAMES = 12; % frames in the record/remove morph animation

    % ---- Shared state ----
    serialObj  = [];
    rssiBuffer = [];
    ptsX = []; ptsY = []; ptsRSSI = []; ptsN = [];
    plotAxes   = [];
    cbarHandle = [];
    youHandle  = [];
    is3D       = false;

    % ---- Animation state ----
    prevZMesh   = [];      % last drawn surface (for the morph)
    prevExtent  = [0 0];
    animateNext = false;   % set by record/remove/load to request a morph
    isBusy      = false;   % true while redrawHeatmap is running
    redrawPending = false;
    ringH = []; ringCx = 0; ringCy = 0; ringZ = 0; ringMaxR = 1;
    newestH     = [];
    animClock   = tic;
    animTimer   = [];

    ACCENT = [0.25 0.5 0.8];
    PANEL  = [0.96 0.96 0.96];

    % ---- Main window ----
    fig = figure('Name', 'WiFi Heatmap - Live Collector & Analyzer', ...
        'NumberTitle', 'off', 'Position', [60 50 1300 740], ...
        'MenuBar', 'none', 'ToolBar', 'none', 'Color', PANEL, ...
        'CloseRequestFcn', @onClose);

    % ---- Left column: connection, live readout, recording ----
    addText([10 715 100 18], 'Serial Port:');
    portPopup  = addPopup([10 690 140 25], {'No ports found'}, []);
    addButton([158 690 100 25], 'Refresh Ports', [], @refreshPorts);
    connectBtn = addButton([266 690 100 25], 'Connect', ACCENT, @toggleConnect);

    addText([10 655 120 18], 'Live RSSI (dBm):');
    liveRssiLabel = addText([10 618 140 34], '--', 22, 'bold');
    addText([170 655 190 18], 'Fresh samples buffered:');
    bufferLabel = addText([170 625 190 26], sprintf('0 / %d', BUF_N), 14, 'bold');

    addText([10 585 55 20], 'X (m):');
    xEdit = addEdit([65 585 60 25], '0', @onPositionChanged);
    addText([140 585 55 20], 'Y (m):');
    yEdit = addEdit([195 585 60 25], '0', @onPositionChanged);

    addButton([10 545 170 32], 'Record Point', ACCENT, @recordPoint);
    addButton([190 545 176 32], 'I Moved - Reset Buffer', [], @onPositionChanged);
    addButton([10 508 110 28], 'Remove Last', [], @removeLast);
    addButton([128 508 110 28], 'Clear All', [], @clearAll);

    % ---- Room / router / display settings ----
    addText([10 474 85 20], 'Room W (m):');
    roomWEdit   = addEdit([98 474 50 25], '5', @onSettingChanged);
    addText([160 474 85 20], 'Room H (m):');
    roomHEdit   = addEdit([248 474 50 25], '5', @onSettingChanged);
    addText([10 442 85 20], 'Router X (m):');
    routerXEdit = addEdit([98 442 50 25], '0', @onSettingChanged);
    addText([160 442 85 20], 'Router Y (m):');
    routerYEdit = addEdit([248 442 50 25], '0', @onSettingChanged);

    addText([10 410 85 20], 'Cutoff (dBm):');
    cutoffEdit  = addEdit([98 410 50 25], '-60', @onSettingChanged);
    addText([160 410 55 20], 'Method:');
    methodPopup = addPopup([218 410 148 25], ...
        {'Bisection', 'False Position', 'Newton-Raphson', 'Secant'}, @onSettingChanged);

    viewPopup = addPopup([10 378 150 25], {'2D Heatmap', '3D Surface'}, @onSettingChanged);
    modePopup = addPopup([168 378 198 25], ...
        {'Honest (mask unmeasured gaps)', 'Full Surface (extrapolated)'}, @onSettingChanged);

    % ---- Recorded points table + save/load ----
    addText([10 352 200 18], 'Recorded points:', [], 'bold');
    pointsTable = uitable('Parent', fig, 'Position', [10 62 356 288], ...
        'ColumnName', {'X (m)', 'Y (m)', 'Avg RSSI (dBm)', 'Samples'}, ...
        'ColumnWidth', {55 55 100 60});
    addButton([10 28 170 28], 'Save Data (.mat)', ACCENT, @saveData);
    addButton([196 28 170 28], 'Load Data (.mat)', [], @loadData);

    % ---- Right column: metrics ----
    addText([1000 705 290 20], 'LIVE METRICS', [], 'bold');
    txtMetrics = uicontrol('Style', 'edit', 'Parent', fig, 'Position', [1000 90 290 610], ...
        'Max', 2, 'Min', 0, 'HorizontalAlignment', 'left', 'FontSize', 10, ...
        'Enable', 'inactive', 'BackgroundColor', [0.93 0.93 0.93]);

    statusLabel = addText([10 4 1280 20], 'Not connected. Select a port and click Connect.');

    animCheck = uicontrol('Style', 'checkbox', 'Parent', fig, ...
        'Position', [400 708 170 22], 'String', 'Animate heatmap', 'Value', 1, ...
        'BackgroundColor', PANEL, 'Callback', @onSettingChanged);
    rotateCheck = uicontrol('Style', 'checkbox', 'Parent', fig, ...
        'Position', [590 708 200 22], 'String', 'Rotate 3D view', 'Value', 0, ...
        'BackgroundColor', PANEL, 'Callback', @onSettingChanged);

    refreshPorts();
    redrawHeatmap();

    animTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.06, ...
        'BusyMode', 'drop', 'TimerFcn', @onTick);
    start(animTimer);

    if nargout > 0
        app = fig;
    end

    % ================= UI helper functions =================

    function h = addText(pos, str, fontSize, fontWeight)
        args = {'Style', 'text', 'Parent', fig, 'Position', pos, 'String', str, ...
            'HorizontalAlignment', 'left', 'BackgroundColor', PANEL};
        if nargin >= 3 && ~isempty(fontSize)
            args = [args, {'FontSize', fontSize}];
        end
        if nargin >= 4 && ~isempty(fontWeight)
            args = [args, {'FontWeight', fontWeight}];
        end
        h = uicontrol(args{:});
    end

    function h = addEdit(pos, str, callback)
        h = uicontrol('Style', 'edit', 'Parent', fig, 'Position', pos, ...
            'String', str, 'Callback', callback);
    end

    function h = addPopup(pos, items, callback)
        args = {'Style', 'popupmenu', 'Parent', fig, 'Position', pos, 'String', items};
        if ~isempty(callback)
            args = [args, {'Callback', callback}];
        end
        h = uicontrol(args{:});
    end

    function h = addButton(pos, str, bgColor, callback)
        args = {'Style', 'pushbutton', 'Parent', fig, 'Position', pos, 'String', str, ...
            'Callback', callback};
        if ~isempty(bgColor)
            args = [args, {'BackgroundColor', bgColor, 'ForegroundColor', 'w', 'FontWeight', 'bold'}];
        end
        h = uicontrol(args{:});
    end

    function v = readNum(h, fallback)
        v = str2double(get(h, 'String'));
        if isnan(v)
            v = fallback;
        end
    end

    function updateBufferLabel()
        set(bufferLabel, 'String', sprintf('%d / %d', numel(rssiBuffer), BUF_N));
        if numel(rssiBuffer) >= BUF_N
            set(bufferLabel, 'ForegroundColor', [0 0.5 0]);
        else
            set(bufferLabel, 'ForegroundColor', [0 0 0]);
        end
    end

    function deleteColorbarIfAny()
        if ~isempty(cbarHandle) && ishandle(cbarHandle)
            prevWarn = warning('off', 'all');
            delete(cbarHandle);
            warning(prevWarn);
        end
        cbarHandle = [];
    end

    % ================= Serial connection =================

    function refreshPorts(~, ~)
        try
            info = instrhwinfo('serial');
            ports = info.AvailableSerialPorts;
        catch
            ports = {};
        end
        if isempty(ports)
            set(portPopup, 'String', {'No ports found'}, 'Value', 1);
        else
            set(portPopup, 'String', ports, 'Value', 1);
        end
    end

    function toggleConnect(~, ~)
        if isempty(serialObj)
            items = get(portPopup, 'String');
            if iscell(items)
                portName = items{get(portPopup, 'Value')};
            else
                portName = items;
            end
            if strcmp(portName, 'No ports found')
                errordlg('No serial port selected.', 'Connect Error');
                return;
            end
            try
                serialObj = serial(portName, 'BaudRate', 115200, 'Terminator', 'LF');
                serialObj.BytesAvailableFcnMode = 'terminator';
                serialObj.BytesAvailableFcn = @onSerialData;
                fopen(serialObj);
                set(connectBtn, 'String', 'Disconnect');
                set(statusLabel, 'String', 'Connected. Walk to a grid point, type its X/Y, wait for the buffer, then Record Point.');
            catch ME
                errordlg(['Failed to connect: ' ME.message], 'Connect Error');
                serialObj = [];
            end
        else
            try
                fclose(serialObj);
                delete(serialObj);
            catch
            end
            serialObj = [];
            set(connectBtn, 'String', 'Connect');
            set(statusLabel, 'String', 'Disconnected.');
        end
    end

    function onSerialData(src, ~)
        try
            ln = fgetl(src);
        catch
            return;
        end
        if ~ischar(ln)
            return;
        end
        parts = strsplit(strtrim(ln), ',');
        if numel(parts) ~= 2
            return;
        end
        rssi = str2double(parts{2});
        if isnan(rssi)
            return;
        end
        rssiBuffer(end+1) = rssi; %#ok<AGROW>
        if numel(rssiBuffer) > BUF_N
            rssiBuffer(1) = [];
        end
        set(liveRssiLabel, 'String', sprintf('%.1f', rssi));

        % Colour the live reading against the cutoff: green = usable, red = below
        cutoffDb = str2double(get(cutoffEdit, 'String'));
        if ~isnan(cutoffDb)
            if rssi >= cutoffDb
                set(liveRssiLabel, 'ForegroundColor', [0 0.5 0]);
            else
                set(liveRssiLabel, 'ForegroundColor', [0.8 0 0]);
            end
        end
        updateBufferLabel();
    end

    % ================= Recording =================

    function onPositionChanged(~, ~)
        % Typing a new X/Y (or clicking 'I Moved') clears stale readings from
        % the previous spot and moves the green "you are here" marker.
        rssiBuffer = [];
        updateBufferLabel();
        set(statusLabel, 'String', 'Buffer reset - stand still and wait for a full buffer before recording.');

        x = str2double(get(xEdit, 'String'));
        y = str2double(get(yEdit, 'String'));
        if isnan(x) || isnan(y)
            return;
        end
        if ~isempty(youHandle) && ishandle(youHandle)
            set(youHandle, 'XData', x, 'YData', y);
        else
            redrawHeatmap();
        end
    end

    function recordPoint(~, ~)
        if numel(rssiBuffer) < BUF_N
            errordlg(sprintf(['Buffer only has %d of %d fresh samples so far - wait a few more seconds.\n\n' ...
                'This usually takes about 3 seconds once you are standing still.'], ...
                numel(rssiBuffer), BUF_N), 'Buffer Not Ready');
            return;
        end
        x = str2double(get(xEdit, 'String'));
        y = str2double(get(yEdit, 'String'));
        if isnan(x) || isnan(y)
            errordlg('X and Y must be numeric.', 'Invalid Position');
            return;
        end
        avgRssi = mean(rssiBuffer);
        n = numel(rssiBuffer);

        ptsX(end+1)    = x;       %#ok<AGROW>
        ptsY(end+1)    = y;       %#ok<AGROW>
        ptsRSSI(end+1) = avgRssi; %#ok<AGROW>
        ptsN(end+1)    = n;       %#ok<AGROW>

        % Reset the buffer so a double-click cannot reuse the same stale data
        rssiBuffer = [];
        updateBufferLabel();

        refreshTable();
        animateNext = true;
        redrawHeatmap();
        set(statusLabel, 'String', sprintf(['Recorded point #%d at (%.2f, %.2f): %.1f dBm (avg of %d fresh samples). ' ...
            'Walk to the next point and click "I Moved - Reset Buffer".'], ...
            numel(ptsX), x, y, avgRssi, n));
    end

    function removeLast(~, ~)
        if isempty(ptsX)
            return;
        end
        ptsX(end) = []; ptsY(end) = []; ptsRSSI(end) = []; ptsN(end) = [];
        refreshTable();
        animateNext = true;
        redrawHeatmap();
    end

    function clearAll(~, ~)
        ptsX = []; ptsY = []; ptsRSSI = []; ptsN = [];
        refreshTable();
        redrawHeatmap();
    end

    function refreshTable()
        set(pointsTable, 'Data', [ptsX(:), ptsY(:), ptsRSSI(:), ptsN(:)]);
    end

    function onSettingChanged(~, ~)
        redrawHeatmap();
    end

    % ================= Save / load =================

    function saveData(~, ~)
        if numel(ptsX) < 3
            errordlg('Record at least 3 points before saving (need enough data to build a surface).', 'Not Enough Data');
            return;
        end
        [fileName, pathName] = uiputfile('heatmap_data.mat', 'Save Heatmap Data As');
        if isequal(fileName, 0)
            return;
        end
        x = ptsX; y = ptsY; rssi = ptsRSSI; nSamples = ptsN; %#ok<NASGU>
        roomWidth  = readNum(roomWEdit, 5);    %#ok<NASGU>
        roomHeight = readNum(roomHEdit, 5);    %#ok<NASGU>
        routerX    = readNum(routerXEdit, 0);  %#ok<NASGU>
        routerY    = readNum(routerYEdit, 0);  %#ok<NASGU>

        save(fullfile(pathName, fileName), 'x', 'y', 'rssi', 'nSamples', ...
            'roomWidth', 'roomHeight', 'routerX', 'routerY');
        set(statusLabel, 'String', ['Saved ' num2str(numel(ptsX)) ' points to ' fullfile(pathName, fileName)]);
    end

    function loadData(~, ~)
        [fileName, pathName] = uigetfile('*.mat', 'Load Heatmap Data');
        if isequal(fileName, 0)
            return;
        end
        s = load(fullfile(pathName, fileName));
        if ~isfield(s, 'x') || ~isfield(s, 'y') || ~isfield(s, 'rssi')
            errordlg('This file does not look like a valid heatmap data file.', 'Load Error');
            return;
        end
        ptsX = s.x(:)';
        ptsY = s.y(:)';
        ptsRSSI = s.rssi(:)';
        if isfield(s, 'nSamples') && numel(s.nSamples) == numel(ptsX)
            ptsN = s.nSamples(:)';
        else
            ptsN = BUF_N * ones(size(ptsX));
        end
        if isfield(s, 'roomWidth'),  set(roomWEdit,   'String', num2str(s.roomWidth));  end
        if isfield(s, 'roomHeight'), set(roomHEdit,   'String', num2str(s.roomHeight)); end
        if isfield(s, 'routerX'),    set(routerXEdit, 'String', num2str(s.routerX));    end
        if isfield(s, 'routerY'),    set(routerYEdit, 'String', num2str(s.routerY));    end

        refreshTable();
        animateNext = true;
        redrawHeatmap();
        set(statusLabel, 'String', sprintf('Loaded %d points from %s. Keep recording to add more.', numel(ptsX), fileName));
    end

    % ================= Live heatmap =================

    function drawYouAreHere(zPlane)
        % Green X at the X/Y currently typed in the position boxes
        x = str2double(get(xEdit, 'String'));
        y = str2double(get(yEdit, 'String'));
        youHandle = [];
        if isnan(x) || isnan(y)
            return;
        end
        if is3D
            youHandle = plot3(plotAxes, x, y, zPlane, 'x', 'Color', [0 0.6 0], ...
                'MarkerSize', 12, 'LineWidth', 2.5);
        else
            youHandle = plot(plotAxes, x, y, 'x', 'Color', [0 0.6 0], ...
                'MarkerSize', 12, 'LineWidth', 2.5);
        end
    end

    function redrawHeatmap()
        % Wrapper: blocks re-entry while a morph is playing, then redraws once
        % more if something asked for a redraw in the meantime.
        if isBusy
            redrawPending = true;
            return;
        end
        isBusy = true;
        guard = onCleanup(@releaseBusy); %#ok<NASGU>
        drawOnce();
        while redrawPending
            redrawPending = false;
            drawOnce();
        end
    end

    function releaseBusy()
        isBusy = false;
    end

    function drawOnce()
        % ---- Read settings ----
        roomW    = readNum(roomWEdit, 5);
        roomH    = readNum(roomHEdit, 5);
        routerX  = readNum(routerXEdit, NaN);
        routerY  = readNum(routerYEdit, NaN);
        cutoffDb = readNum(cutoffEdit, -60);
        if roomW <= 0, roomW = 5; end
        if roomH <= 0, roomH = 5; end

        methodItems = get(methodPopup, 'String');
        selectedAlg = methodItems{get(methodPopup, 'Value')};
        viewItems   = get(viewPopup, 'String');
        is3D        = strcmp(viewItems{get(viewPopup, 'Value')}, '3D Surface');
        modeItems   = get(modePopup, 'String');
        useFull     = strcmp(modeItems{get(modePopup, 'Value')}, 'Full Surface (extrapolated)');

        n = numel(ptsX);

        % The map covers the room, stretched if any point lies beyond it
        xMax = roomW;
        yMax = roomH;
        if n > 0
            xMax = max(xMax, max(ptsX));
            yMax = max(yMax, max(ptsY));
        end

        % ---- Fresh axes every redraw (avoids legacy colorbar handle bugs) ----
        deleteColorbarIfAny();
        if ishandle(plotAxes)
            delete(plotAxes);
        end
        plotAxes = axes('Parent', fig, 'Units', 'pixels', 'Position', [400 90 580 590]);
        hold(plotAxes, 'on');
        youHandle = [];
        ringH = [];
        newestH = [];

        % ---- Not enough points yet: show what we have and wait ----
        if n < 3
            is3D = false;
            prevZMesh = [];
            animateNext = false;
            if n > 0
                plot(plotAxes, ptsX, ptsY, 'ro', 'MarkerFaceColor', 'r', 'MarkerEdgeColor', 'k');
            end
            addRouterRings(routerX, routerY, xMax, yMax, 0);
            if ~isnan(routerX) && ~isnan(routerY)
                plot(plotAxes, routerX, routerY, 'p', 'MarkerSize', 16, ...
                    'MarkerFaceColor', 'y', 'MarkerEdgeColor', 'k');
            end
            drawYouAreHere(0);
            xlim(plotAxes, [0 xMax]);
            ylim(plotAxes, [0 yMax]);
            xlabel(plotAxes, 'X Position (meters)');
            ylabel(plotAxes, 'Y Position (meters)');
            title(plotAxes, sprintf('Record at least 3 points to build the heatmap (%d so far)', n));
            grid(plotAxes, 'on');
            hold(plotAxes, 'off');
            set(txtMetrics, 'String', sprintf('LIVE METRICS\n\nPoints recorded: %d\n\nRecord at least 3 points\nto build the heatmap.', n));
            return;
        end

        % ---- IDW surface + distance mask (one distance matrix, reused) ----
        xc = ptsX(:);
        yc = ptsY(:);
        zc = ptsRSSI(:);

        gridX = linspace(0, xMax, RES_LIVE);
        gridY = linspace(0, yMax, RES_LIVE);
        [XMesh, YMesh] = meshgrid(gridX, gridY);

        dx    = bsxfun(@minus, XMesh(:), xc');   % [cells x points]
        dy    = bsxfun(@minus, YMesh(:), yc');
        dists = sqrt(dx.^2 + dy.^2);

        [nearestVec, nearestIdx] = min(dists, [], 2);
        exactMatch = nearestVec < 1e-5;

        weights = 1 ./ (dists .^ IDW_POWER);
        ZVec    = (weights * zc) ./ sum(weights, 2);
        ZVec(exactMatch) = zc(nearestIdx(exactMatch));

        ZMesh     = reshape(ZVec, size(XMesh));
        supported = reshape(nearestVec, size(XMesh)) <= MAX_DIST;

        if useFull
            ZPlot    = ZMesh;
            rootMask = true(size(supported));
        else
            ZPlot    = ZMesh;
            ZPlot(~supported) = NaN;
            rootMask = supported;
        end

        % ---- Root-finding: trace the cutoff boundary row by row ----
        bX = []; bY = [];
        iterCount = 0;
        crossings = 0;

        for r = 1:RES_LIVE
            rowZ = ZMesh(r, :);
            zeroCrossings = find(diff(sign(rowZ - cutoffDb)) ~= 0);

            for k = 1:numel(zeroCrossings)
                cIdx = zeroCrossings(k);
                if ~rootMask(r, cIdx) || ~rootMask(r, cIdx + 1)
                    continue;
                end

                lowBound  = gridX(cIdx);
                highBound = gridX(cIdx + 1);

                objFunc = @(x) interp1(gridX, rowZ, x, 'linear') - cutoffDb;
                dfunc   = @(x) (interp1(gridX, rowZ, min(x + 1e-4, xMax), 'linear') - ...
                                interp1(gridX, rowZ, max(x - 1e-4, 0), 'linear')) / 2e-4;

                try
                    switch selectedAlg
                        case 'Bisection'
                            [rootVal, iters] = bisection_method(objFunc, lowBound, highBound, 1e-4, 50);
                        case 'False Position'
                            [rootVal, iters] = falseposition_method(objFunc, lowBound, highBound, 1e-4, 50);
                        case 'Newton-Raphson'
                            [rootVal, iters] = newtonraphson_method(objFunc, dfunc, (lowBound + highBound) / 2, 1e-4, 50);
                        case 'Secant'
                            [rootVal, iters] = secant_method(objFunc, lowBound, highBound, 1e-4, 50);
                    end
                    if rootVal >= lowBound && rootVal <= highBound
                        bX(end+1) = rootVal;      %#ok<AGROW>
                        bY(end+1) = gridY(r);     %#ok<AGROW>
                        iterCount = iterCount + iters;
                        crossings = crossings + 1;
                    end
                catch
                end
            end
        end

        % ---- Coverage by 2D trapezoidal integration ----
        totalArea = xMax * yMax;
        if useFull
            covered      = trapz(gridY, trapz(gridX, double(ZMesh >= cutoffDb), 2), 1);
            measuredArea = totalArea;
            usablePct    = 100 * covered / totalArea;
        else
            covered      = trapz(gridY, trapz(gridX, double(ZMesh >= cutoffDb & supported), 2), 1);
            measuredArea = trapz(gridY, trapz(gridX, double(supported), 2), 1);
            if measuredArea > 0
                usablePct = 100 * covered / measuredArea;
            else
                usablePct = 0;
            end
        end
        measuredPct = 100 * measuredArea / totalArea;

        % ---- Colour range pinned to the real data range ----
        cLo = min(ZMesh(:));
        cHi = max(ZMesh(:));
        if cHi <= cLo
            cHi = cLo + 1;
        end

        % ---- Draw ----
        minZ   = cLo - 3;
        maxZ   = cHi + 2;
        labelZ = maxZ + 4;

        colormap(plotAxes, jet);
        caxis(plotAxes, [cLo cHi]);
        xlim(plotAxes, [0 xMax]);
        ylim(plotAxes, [0 yMax]);
        if is3D
            zlim(plotAxes, [minZ labelZ + 2]);
            view(plotAxes, [-37.5 30]);
        end

        % ---- Morph animation: old surface flows into the new one ----
        doMorph = animateNext && get(animCheck, 'Value') == 1;
        animateNext = false;
        if doMorph
            validPrev = ~isempty(prevZMesh) && isequal(size(prevZMesh), size(ZMesh)) ...
                && isequal(prevExtent, [xMax yMax]);
            if validPrev
                startZ = prevZMesh;
            else
                startZ = mean(zc) * ones(size(ZMesh));   % first map blooms from flat
            end
            for f = 1:MORPH_FRAMES - 1
                e = 0.5 - 0.5 * cos(pi * f / MORPH_FRAMES);   % smooth ease in/out
                ZFrame = startZ + (ZMesh - startZ) * e;
                ZFrameMask = ZFrame;
                if ~useFull
                    ZFrameMask(~supported) = NaN;
                end
                cla(plotAxes);
                hold(plotAxes, 'on');
                drawField(ZFrame, ZFrameMask, XMesh, YMesh, minZ, useFull);
                drawnow;
                pause(0.015);
            end
            cla(plotAxes);
            hold(plotAxes, 'on');
            youHandle = [];
        end

        drawField(ZMesh, ZPlot, XMesh, YMesh, minZ, useFull);

        warnState = warning('off', 'all');
        cbarHandle = colorbar(plotAxes);
        warning(warnState);
        ylabel(cbarHandle, 'RSSI (dBm)');

        % Root-found cutoff boundary
        if ~isempty(bX)
            if is3D
                plot3(plotAxes, bX, bY, cutoffDb * ones(size(bX)), 'wo', ...
                    'MarkerFaceColor', 'w', 'MarkerEdgeColor', 'k', 'MarkerSize', 4);
            else
                plot(plotAxes, bX, bY, 'wo', 'MarkerFaceColor', 'w', ...
                    'MarkerEdgeColor', 'k', 'MarkerSize', 4);
            end
        end

        % Measured points with RSSI labels (newest point highlighted)
        for i = 1:n
            if is3D
                plot3(plotAxes, [xc(i) xc(i)], [yc(i) yc(i)], [minZ labelZ], 'k:');
                plot3(plotAxes, xc(i), yc(i), zc(i), 'ro', 'MarkerFaceColor', 'r', ...
                    'MarkerEdgeColor', 'k', 'MarkerSize', 7);
                text(xc(i), yc(i), labelZ, sprintf(' %.0f dBm', zc(i)), 'Parent', plotAxes, ...
                    'FontSize', 8, 'FontWeight', 'bold', 'BackgroundColor', [1 1 1], ...
                    'EdgeColor', 'k', 'Margin', 1);
            else
                plot(plotAxes, xc(i), yc(i), 'ro', 'MarkerFaceColor', 'r', ...
                    'MarkerEdgeColor', 'k', 'MarkerSize', 7);
                text(xc(i) + 0.04 * xMax, yc(i) + 0.03 * yMax, sprintf('%.0f', zc(i)), ...
                    'Parent', plotAxes, 'FontSize', 8, 'FontWeight', 'bold', ...
                    'BackgroundColor', [1 1 1], 'EdgeColor', 'k', 'Margin', 1);
            end
        end
        if is3D
            newestH = plot3(plotAxes, xc(n), yc(n), zc(n), 'o', 'MarkerFaceColor', 'y', ...
                'MarkerEdgeColor', 'k', 'MarkerSize', 11);
        else
            newestH = plot(plotAxes, xc(n), yc(n), 'o', 'MarkerFaceColor', 'y', ...
                'MarkerEdgeColor', 'k', 'MarkerSize', 11);
        end

        % Router signal rings (animated by the timer)
        if is3D
            addRouterRings(routerX, routerY, xMax, yMax, minZ);
        else
            addRouterRings(routerX, routerY, xMax, yMax, 0);
        end

        % Router marker (only if it lies on the map)
        if ~isnan(routerX) && ~isnan(routerY) && routerX <= xMax && routerY <= yMax
            if is3D
                rd = sqrt((xc - routerX).^2 + (yc - routerY).^2);
                [rMin, rIdx] = min(rd);
                if rMin < 1e-5
                    routerZ = zc(rIdx);
                else
                    rw = 1 ./ (rd .^ IDW_POWER);
                    routerZ = sum(rw .* zc) / sum(rw);
                end
                plot3(plotAxes, routerX, routerY, routerZ, 'p', 'MarkerSize', 16, ...
                    'MarkerFaceColor', 'y', 'MarkerEdgeColor', 'k');
            else
                plot(plotAxes, routerX, routerY, 'p', 'MarkerSize', 16, ...
                    'MarkerFaceColor', 'y', 'MarkerEdgeColor', 'k');
            end
        end

        % "You are here" marker, drawn last so it sits on top
        if is3D
            drawYouAreHere(minZ);
        else
            drawYouAreHere(0);
        end

        % ---- Axes formatting ----
        xlabel(plotAxes, 'X Position (meters)');
        ylabel(plotAxes, 'Y Position (meters)');
        xlim(plotAxes, [0 xMax]);
        ylim(plotAxes, [0 yMax]);
        grid(plotAxes, 'on');
        if is3D
            zlabel(plotAxes, 'RSSI (dBm)');
            zlim(plotAxes, [minZ labelZ + 2]);
            view(plotAxes, [-37.5 30]);
            axis(plotAxes, 'normal');
        else
            view(plotAxes, 2);
        end
        if useFull
            modeTag = 'full surface';
        else
            modeTag = 'gray = no data nearby';
        end
        title(plotAxes, sprintf('Live WiFi Heatmap - %d points, cutoff %.0f dBm (%s)', n, cutoffDb, modeTag));
        hold(plotAxes, 'off');

        prevZMesh  = ZMesh;
        prevExtent = [xMax yMax];

        % ---- Metrics panel ----
        meanIters = 0;
        if crossings > 0
            meanIters = iterCount / crossings;
        end
        set(txtMetrics, 'String', sprintf([ ...
            'LIVE METRICS\n\n' ...
            'Points recorded: %d\n' ...
            'Newest: (%.2f, %.2f) m\n' ...
            '        %.1f dBm\n\n' ...
            'MAP AREA:\n' ...
            'Width (X): %.2f m\n' ...
            'Height (Y): %.2f m\n' ...
            'Total area: %.2f sq m\n\n' ...
            'COVERAGE (cutoff %.1f dBm):\n' ...
            'Room measured: %.1f%%\n' ...
            'Usable signal: %.1f%%\n' ...
            '  (of the %s)\n' ...
            'Covered area: %.2f sq m\n\n' ...
            'ROOT FINDING:\n' ...
            'Method: %s\n' ...
            'Boundary crossings: %d\n' ...
            'Avg iterations: %.2f\n'], ...
            n, xc(n), yc(n), zc(n), ...
            xMax, yMax, totalArea, ...
            cutoffDb, measuredPct, usablePct, ...
            ternary(useFull, 'whole map', 'measured area'), covered, ...
            selectedAlg, crossings, meanIters));
    end

    function drawField(Zfull, Zmask, XMesh, YMesh, minZ, useFull)
        % Draws the heatmap field only (used for morph frames and the final frame)
        if is3D
            surface('Parent', plotAxes, 'XData', XMesh, 'YData', YMesh, ...
                'ZData', minZ * ones(size(XMesh)), 'CData', Zfull, ...
                'FaceColor', 'texturemap', 'EdgeColor', 'none', 'FaceAlpha', 1);
            surf(plotAxes, XMesh, YMesh, Zmask, 'FaceAlpha', 0.95, ...
                'EdgeColor', [0.2 0.2 0.2], 'LineWidth', 0.3, 'FaceColor', 'interp');
        else
            contourf(plotAxes, XMesh, YMesh, Zmask, 20, 'LineStyle', 'none');
            if ~useFull
                set(plotAxes, 'Color', [0.75 0.75 0.75]);   % gray shows through NaN gaps
            end
        end
    end

    function addRouterRings(rx, ry, xMax, yMax, zPlane)
        ringH = [];
        if isnan(rx) || isnan(ry) || rx > xMax || ry > yMax
            return;
        end
        ringCx = rx;
        ringCy = ry;
        ringZ  = zPlane;
        % Rings grow until they reach the farthest corner of the map
        ringMaxR = sqrt(max(rx, xMax - rx)^2 + max(ry, yMax - ry)^2);
        for k = 1:3
            if is3D
                ringH(k) = plot3(plotAxes, rx, ry, zPlane, '-', ...
                    'Color', [1 1 1], 'LineWidth', 1.5);
            else
                ringH(k) = plot(plotAxes, rx, ry, '-', ...
                    'Color', [1 1 1], 'LineWidth', 1.5);
            end
        end
    end

    function onTick(~, ~)
        % Timer callback: moves the rings, pulses the newest point, spins 3D view
        if isBusy || isempty(fig) || ~ishandle(fig)
            return;
        end
        try
            t  = toc(animClock);
            on = get(animCheck, 'Value') == 1;

            for k = 1:numel(ringH)
                if ~ishandle(ringH(k))
                    continue;
                end
                if ~on
                    set(ringH(k), 'Visible', 'off');
                    continue;
                end
                ph  = mod(0.35 * t + (k - 1) / numel(ringH), 1);   % 0..1 life of this ring
                rad = ph * ringMaxR;
                th  = linspace(0, 2 * pi, 72);
                xs  = ringCx + rad * cos(th);
                ys  = ringCy + rad * sin(th);
                lw  = 0.5 + 2.5 * (1 - ph);                         % thins out as it fades
                if is3D
                    set(ringH(k), 'XData', xs, 'YData', ys, ...
                        'ZData', ringZ * ones(size(xs)), 'LineWidth', lw, 'Visible', 'on');
                else
                    set(ringH(k), 'XData', xs, 'YData', ys, ...
                        'LineWidth', lw, 'Visible', 'on');
                end
            end

            if on && ~isempty(newestH) && ishandle(newestH)
                set(newestH, 'MarkerSize', 11 + 4 * sin(2 * pi * 0.8 * t));
            end

            if on && is3D && get(rotateCheck, 'Value') == 1 && ishandle(plotAxes)
                view(plotAxes, [-37.5 + 12 * t, 30]);
            end
            drawnow;
        catch
        end
    end

    function s = ternary(cond, a, b)
        if cond
            s = a;
        else
            s = b;
        end
    end

    % ================= Window close =================

    function onClose(~, ~)
        if ~isempty(animTimer)
            try
                stop(animTimer);
                delete(animTimer);
            catch
            end
            animTimer = [];
        end
        if ~isempty(serialObj)
            try
                fclose(serialObj);
                delete(serialObj);
            catch
            end
        end
        deleteColorbarIfAny();
        delete(fig);
    end

end