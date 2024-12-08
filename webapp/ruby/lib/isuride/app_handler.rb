# frozen_string_literal: true

require 'ulid'

require 'isuride/base_handler'
require 'isuride/payment_gateway'

module Isuride
  class AppHandler < BaseHandler
    CurrentUser = Data.define(
      :id,
      :username,
      :firstname,
      :lastname,
      :date_of_birth,
      :access_token,
      :invitation_code,
      :created_at,
      :updated_at,
    )

    before do
      if request.path == '/api/app/users'
        next
      end

      access_token = cookies[:app_session]
      if access_token.nil?
        raise HttpError.new(401, 'app_session cookie is required')
      end
      user = db.xquery('SELECT * FROM users WHERE access_token = ?', access_token).first
      if user.nil?
        raise HttpError.new(401, 'invalid access token')
      end

      @current_user = CurrentUser.new(**user)
    end

    AppPostUsersRequest = Data.define(
      :username,
      :firstname,
      :lastname,
      :date_of_birth,
      :invitation_code,
    )

    # POST /api/app/users
    post '/users' do
      req = bind_json(AppPostUsersRequest)
      if req.username.nil? || req.firstname.nil? || req.lastname.nil? || req.date_of_birth.nil?
        raise HttpError.new(400, 'required fields(username, firstname, lastname, date_of_birth) are empty')
      end

      user_id = ULID.generate
      access_token = SecureRandom.hex(32)
      invitation_code = SecureRandom.hex(15)

      db_transaction do |tx|
        tx.xquery('INSERT INTO users (id, username, firstname, lastname, date_of_birth, access_token, invitation_code) VALUES (?, ?, ?, ?, ?, ?, ?)', user_id, req.username, req.firstname, req.lastname, req.date_of_birth, access_token, invitation_code)

	# 初回登録キャンペーンのクーポンを付与
        tx.xquery('INSERT INTO coupons (user_id, code, discount) VALUES (?, ?, ?)', user_id, 'CP_NEW2024', 3000)

	# 招待コードを使った登録
        unless req.invitation_code.nil? || req.invitation_code.empty?
          # 招待する側の招待数をチェック
          coupons = tx.xquery('SELECT * FROM coupons WHERE code = ? FOR UPDATE', "INV_#{req.invitation_code}").to_a
          if coupons.size >= 3
            raise HttpError.new(400, 'この招待コードは使用できません。')
          end

          # ユーザーチェック
          inviter = tx.xquery('SELECT * FROM users WHERE invitation_code = ?', req.invitation_code).first
          unless inviter
            raise HttpError.new(400, 'この招待コードは使用できません。')
          end

          # 招待クーポン付与
          tx.xquery('INSERT INTO coupons (user_id, code, discount) VALUES (?, ?, ?)', user_id, "INV_#{req.invitation_code}", 1500)
          # 招待した人にもRewardを付与
          tx.xquery("INSERT INTO coupons (user_id, code, discount) VALUES (?, CONCAT(?, '_', FLOOR(UNIX_TIMESTAMP(NOW(3))*1000)), ?)", inviter.fetch(:id), "RWD_#{req.invitation_code}", 1000)
        end
      end

      cookies.set(:app_session, httponly: false, value: access_token, path: '/')
      status(201)
      json(id: user_id, invitation_code:)
    end

    AppPostPaymentMethodsRequest = Data.define(:token)

    # POST /api/app/payment-methods
    post '/payment-methods' do
      req = bind_json(AppPostPaymentMethodsRequest)
      if req.token.nil?
        raise HttpError.new(400, 'token is required but was empty')
      end

      db.xquery('INSERT INTO payment_tokens (user_id, token) VALUES (?, ?)', @current_user.id, req.token)

      status(204)
    end

    # GET /api/app/rides
    get '/rides' do
      items = db_transaction do |tx|
        rides = tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC', @current_user.id)

        rides.filter_map do |ride|
          status = get_latest_ride_status(tx, ride.fetch(:id))
          if status != 'COMPLETED'
            next
          end

          fare = calculate_discounted_fare(tx, @current_user.id, ride, ride.fetch(:pickup_latitude),  ride.fetch(:pickup_longitude), ride.fetch(:destination_latitude), ride.fetch(:destination_longitude))

          chair = tx.xquery('SELECT * FROM chairs WHERE id = ?', ride.fetch(:chair_id)).first
          owner = tx.xquery('SELECT * FROM owners WHERE id = ?', chair.fetch(:owner_id)).first

          {
            id: ride.fetch(:id),
            pickup_coordinate: {
              latitude: ride.fetch(:pickup_latitude),
              longitude: ride.fetch(:pickup_longitude),
            },
            destination_coordinate: {
              latitude: ride.fetch(:destination_latitude),
              longitude: ride.fetch(:destination_longitude),
            },
            fare:,
            evaluation: ride.fetch(:evaluation),
            requested_at: time_msec(ride.fetch(:created_at)),
            completed_at: time_msec(ride.fetch(:updated_at)),
            chair: {
              id: chair.fetch(:id),
              name: chair.fetch(:name),
              model: chair.fetch(:model),
              owner: owner.fetch(:name),
            },
          }
        end
      end

      json(rides: items)
    end

    Coordinate = Data.define(:latitude, :longitude)

    AppPostRidesRequest = Data.define(:pickup_coordinate, :destination_coordinate) do
      def initialize(pickup_coordinate:, destination_coordinate:, **kwargs)
        super(
          pickup_coordinate: Coordinate.new(**pickup_coordinate),
          destination_coordinate: Coordinate.new(**destination_coordinate),
          **kwargs,
        )
      end
    end

    # POST /api/app/rides
    post '/rides' do
      req = bind_json(AppPostRidesRequest)
      if req.pickup_coordinate.nil? || req.destination_coordinate.nil?
        raise HttpError.new(400, 'required fields(pickup_coordinate, destination_coordinate) are empty')
      end

      ride_id = ULID.generate

      fare = db_transaction do |tx|
        rides = tx.xquery('SELECT * FROM rides WHERE user_id = ?', @current_user.id).to_a

        continuing_ride_count = rides.count do |ride|
          status = get_latest_ride_status(tx, ride.fetch(:id))
          status != 'COMPLETED'
        end

        if continuing_ride_count > 0
          raise HttpError.new(429, 'ride already exists')
        end

        tx.xquery(
          'INSERT INTO rides (id, user_id, pickup_latitude, pickup_longitude, destination_latitude, destination_longitude) VALUES (?, ?, ?, ?, ?, ?)',
          ride_id,
          @current_user.id,
          req.pickup_coordinate.latitude,
          req.pickup_coordinate.longitude,
          req.destination_coordinate.latitude,
          req.destination_coordinate.longitude,
        )

        tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride_id, 'MATCHING')

        ride_count = tx.xquery('SELECT COUNT(*) FROM rides WHERE user_id = ?', @current_user.id, as: :array).first[0]

        if ride_count == 1
          # 初回利用で、初回利用クーポンがあれば必ず使う
          coupon = tx.xquery("SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL FOR UPDATE", @current_user.id).first
          if coupon.nil?
            # 無ければ他のクーポンを付与された順番に使う
            coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE', @current_user.id).first
            unless coupon.nil?
              tx.xquery('UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = ?', ride_id, @current_user.id, coupon.fetch(:code))
            end
          else
            tx.xquery("UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = 'CP_NEW2024'", ride_id, @current_user.id)
          end
        else
          # 他のクーポンを付与された順番に使う
          coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE', @current_user.id).first
          unless coupon.nil?
            tx.xquery('UPDATE coupons SET used_by = ? WHERE user_id = ? AND code = ?', ride_id, @current_user.id, coupon.fetch(:code))
          end
        end

        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first

        calculate_discounted_fare(tx, @current_user.id, ride, req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude)
      end

      status(202)
      json(ride_id:, fare:)
    end

    AppPostRidesEstimatedFareRequest = Data.define(:pickup_coordinate, :destination_coordinate) do
      def initialize(pickup_coordinate:, destination_coordinate:, **kwargs)
        super(
          pickup_coordinate: (Coordinate.new(**pickup_coordinate) unless pickup_coordinate.nil?),
          destination_coordinate: (Coordinate.new(**destination_coordinate) unless destination_coordinate.nil?),
          **kwargs,
        )
      end
    end

    # POST /api/app/rides/estimated-fare
    post '/rides/estimated-fare' do
      req = bind_json(AppPostRidesEstimatedFareRequest)
      if req.pickup_coordinate.nil? || req.destination_coordinate.nil?
        raise HttpError.new(400, 'required fields(pickup_coordinate, destination_coordinate) are empty')
      end

      discounted = db_transaction do |tx|
        calculate_discounted_fare(tx, @current_user.id, nil, req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude)
      end

      json(
        fare: discounted,
        discount: calculate_fare(req.pickup_coordinate.latitude, req.pickup_coordinate.longitude, req.destination_coordinate.latitude, req.destination_coordinate.longitude) - discounted,
      )
    end

    AppPostRideEvaluationRequest = Data.define(:evaluation)

    # POST /api/app/rides/:ride_id/evaluation
    post '/rides/:ride_id/evaluation' do
      ride_id = params[:ride_id]

      req = bind_json(AppPostRideEvaluationRequest)
      if req.evaluation < 1 || req.evaluation > 5
        raise HttpError.new(400, 'evaluation must be between 1 and 5')
      end

      response = db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.nil?
          raise HttpError.new(404, 'ride not found')
        end
        status = get_latest_ride_status(tx, ride.fetch(:id))

        if status != 'ARRIVED'
          raise HttpError.new(400, 'not arrived yet')
        end

        tx.xquery('UPDATE rides SET evaluation = ? WHERE id = ?', req.evaluation, ride_id)
        if tx.affected_rows == 0
          raise HttpError.new(404, 'ride not found')
        end

        tx.xquery('INSERT INTO ride_statuses (id, ride_id, status) VALUES (?, ?, ?)', ULID.generate, ride_id, 'COMPLETED')

        ride = tx.xquery('SELECT * FROM rides WHERE id = ?', ride_id).first
        if ride.nil?
          raise HttpError.new(404, 'ride not found')
        end

        payment_token = tx.xquery('SELECT * FROM payment_tokens WHERE user_id = ?', ride.fetch(:user_id)).first
        if payment_token.nil?
          raise HttpError.new(400, 'payment token not registered')
        end

        fare = calculate_discounted_fare(tx, ride.fetch(:user_id), ride, ride.fetch(:pickup_latitude), ride.fetch(:pickup_longitude), ride.fetch(:destination_latitude), ride.fetch(:destination_longitude))

        payment_gateway_url = tx.query("SELECT value FROM settings WHERE name = 'payment_gateway_url'").first.fetch(:value)

        begin
          PaymentGateway.new(payment_gateway_url, payment_token.fetch(:token)).request_post_payment(amount: fare) do
            tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at ASC', ride.fetch(:user_id))
          end
        rescue PaymentGateway::ErroredUpstream => e
          raise HttpError.new(502, e.message)
        end

        {
          completed_at: time_msec(ride.fetch(:updated_at)),
        }
      end

      json(response)
    end

    # GET /api/app/notification
    get '/notification' do
      response = db_transaction do |tx|
        ride = tx.xquery('SELECT * FROM rides WHERE user_id = ? ORDER BY created_at DESC LIMIT 1', @current_user.id).first
        if ride.nil?
          { data: nil, retry_after_ms: 30 }
        else
          yet_sent_ride_status = tx.xquery('SELECT * FROM ride_statuses WHERE ride_id = ? AND app_sent_at IS NULL ORDER BY created_at ASC LIMIT 1', ride[:id]).first
    
          status =
            if yet_sent_ride_status
              yet_sent_ride_status[:status]
            else
              # 最新ステータスをキャッシュしている場合はそちらを使用
              # なければ既存のget_latest_ride_statusをインデックス付で高速化
              get_latest_ride_status(tx, ride[:id])
            end
    
          fare = calculate_discounted_fare(tx, @current_user.id, ride, ride[:pickup_latitude], ride[:pickup_longitude], ride[:destination_latitude], ride[:destination_longitude])
    
          data = {
            ride_id: ride[:id],
            pickup_coordinate: {
              latitude: ride[:pickup_latitude],
              longitude: ride[:pickup_longitude],
            },
            destination_coordinate: {
              latitude: ride[:destination_latitude],
              longitude: ride[:destination_longitude],
            },
            fare: fare,
            status: status,
            created_at: time_msec(ride[:created_at]),
            updated_at: time_msec(ride[:updated_at]),
          }
    
          if ride[:chair_id]
            chair = tx.xquery('SELECT id, name, model FROM chairs WHERE id = ?', ride[:chair_id]).first
            # 改善後のget_chair_statsを使用（N+1解消済み）
            stats = get_chair_stats(tx, chair[:id])
            data[:chair] = {
              id: chair[:id],
              name: chair[:name],
              model: chair[:model],
              stats: stats,
            }
          end
    
          # ステータス通知済み更新
          if yet_sent_ride_status
            tx.xquery('UPDATE ride_statuses SET app_sent_at = CURRENT_TIMESTAMP(6) WHERE id = ?', yet_sent_ride_status[:id])
          end
    
          { data: data, retry_after_ms: 30 }
        end
      end
    
      json(response)
    end

    # GET /api/app/nearby-chairs
    get '/nearby-chairs' do
      latitude, longitude, distance = parse_query_params(params)
    
      response = db_transaction do |tx|
        # 1. アクティブなchairsを一括取得
        chairs = tx.xquery('SELECT id, name, model FROM chairs WHERE is_active = 1')
    
        chair_ids = chairs.map { |c| c[:id] }
        if chair_ids.empty?
          next {
            chairs: [],
            retrieved_at: time_msec(tx.query('SELECT CURRENT_TIMESTAMP(6)', as: :array).first[0])
          }
        end
    
        # 2. 全chairsに対して最新ライドを一括取得
        rides = tx.xquery(<<~SQL, chair_ids)
          SELECT r.chair_id, r.id AS ride_id
          FROM rides r
          JOIN (
            SELECT chair_id, MAX(created_at) AS max_created_at
            FROM rides
            WHERE chair_id IN (#{(['?'] * chair_ids.size).join(',')})
            GROUP BY chair_id
          ) lr ON lr.chair_id = r.chair_id AND lr.max_created_at = r.created_at
        SQL
    
        # chair_id -> ride_idのマッピング
        chair_to_ride = rides.each_with_object({}) { |r, h| h[r[:chair_id]] = r[:ride_id] }
    
        # 3. 最新ステータスを一括取得
        ride_ids = chair_to_ride.values.compact
        statuses = {}
        unless ride_ids.empty?
          ride_statuses = tx.xquery(<<~SQL, ride_ids)
            SELECT rs.ride_id, rs.status
            FROM ride_statuses rs
            JOIN (
              SELECT ride_id, MAX(created_at) AS max_created_at
              FROM ride_statuses
              WHERE ride_id IN (#{(['?'] * ride_ids.size).join(',')})
              GROUP BY ride_id
            ) ls ON ls.ride_id = rs.ride_id AND ls.max_created_at = rs.created_at
          SQL
    
          ride_statuses.each do |rs|
            statuses[rs[:ride_id]] = rs[:status]
          end
        end
    
        # 4. 最新位置情報を一括取得
        chair_locations = tx.xquery(<<~SQL, chair_ids)
          SELECT cl.chair_id, cl.latitude, cl.longitude
          FROM chair_locations cl
          JOIN (
            SELECT chair_id, MAX(created_at) AS max_created_at
            FROM chair_locations
            WHERE chair_id IN (#{(['?'] * chair_ids.size).join(',')})
            GROUP BY chair_id
          ) lcl ON lcl.chair_id = cl.chair_id AND lcl.max_created_at = cl.created_at
        SQL
    
        location_map = {}
        chair_locations.each do |loc|
          location_map[loc[:chair_id]] = { latitude: loc[:latitude], longitude: loc[:longitude] }
        end
    
        # 5. フィルタリング
        nearby_chairs = []
        chairs.each do |c|
          ride_id = chair_to_ride[c[:id]]
          # ライドが存在し、かつ完了していない場合はスキップ
          if ride_id && statuses[ride_id] != 'COMPLETED'
            next
          end
    
          loc = location_map[c[:id]]
          next if loc.nil?
    
          if calculate_distance(latitude, longitude, loc[:latitude], loc[:longitude]) <= distance
            nearby_chairs << {
              id: c[:id],
              name: c[:name],
              model: c[:model],
              current_coordinate: {
                latitude: loc[:latitude],
                longitude: loc[:longitude],
              },
            }
          end
        end
    
        retrieved_at = tx.query('SELECT CURRENT_TIMESTAMP(6)', as: :array).first[0]
    
        {
          chairs: nearby_chairs,
          retrieved_at: time_msec(retrieved_at),
        }
      end
    
      json(response)
    end

    helpers do
      def get_chair_stats(tx, chair_id)
        rides = tx.xquery('SELECT id, evaluation FROM rides WHERE chair_id = ? ORDER BY updated_at DESC', chair_id)
        ride_ids = rides.map { |r| r[:id] }
        return { total_rides_count: 0, total_evaluation_avg: 0.0 } if ride_ids.empty?
      
        # ride_idsに対する全statusesを一回で取得
        ride_statuses_all = tx.xquery(<<~SQL, ride_ids)
          SELECT ride_id, status, created_at
          FROM ride_statuses
          WHERE ride_id IN (#{(['?'] * ride_ids.size).join(',')})
          ORDER BY ride_id, created_at
        SQL
      
        # ride_id ごとにstatusをグルーピング
        statuses_by_ride = {}
        ride_statuses_all.each do |rs|
          (statuses_by_ride[rs[:ride_id]] ||= []) << rs
        end
      
        total_rides_count = 0
        total_evaluation = 0.0
      
        rides.each do |ride|
          statuses = statuses_by_ride[ride[:id]]
          next if statuses.nil?
      
          arrived_at = nil
          pickup_at = nil
          is_completed = false
          statuses.each do |st|
            case st[:status]
            when 'ARRIVED'
              arrived_at = st[:created_at]
            when 'CARRYING'
              pickup_at = st[:created_at]
            when 'COMPLETED'
              is_completed = true
            end
          end
      
          if arrived_at && pickup_at && is_completed
            total_rides_count += 1
            total_evaluation += ride[:evaluation]
          end
        end
      
        total_evaluation_avg = total_rides_count > 0 ? (total_evaluation / total_rides_count) : 0.0
      
        {
          total_rides_count: total_rides_count,
          total_evaluation_avg: total_evaluation_avg,
        }
      end
      

      def calculate_discounted_fare(tx, user_id, ride, pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        discount =
          if !ride.nil?
            dest_latitude = ride.fetch(:destination_latitude)
            dest_longitude = ride.fetch(:destination_longitude)
            pickup_latitude = ride.fetch(:pickup_latitude)
            pickup_longitude = ride.fetch(:pickup_longitude)

            # すでにクーポンが紐づいているならそれの割引額を参照
            coupon = tx.xquery('SELECT * FROM coupons WHERE used_by = ?', ride.fetch(:id)).first
            if coupon.nil?
              0
            else
              coupon.fetch(:discount)
            end
          else
            # 初回利用クーポンを最優先で使う
            coupon = tx.xquery("SELECT * FROM coupons WHERE user_id = ? AND code = 'CP_NEW2024' AND used_by IS NULL", user_id).first
            if coupon.nil?
              # 無いなら他のクーポンを付与された順番に使う
              coupon = tx.xquery('SELECT * FROM coupons WHERE user_id = ? AND used_by IS NULL ORDER BY created_at LIMIT 1', user_id).first
              if coupon.nil?
                0
              else
                coupon.fetch(:discount)
              end
            else
              coupon.fetch(:discount)
            end
          end

        metered_fare = FARE_PER_DISTANCE * calculate_distance(pickup_latitude, pickup_longitude, dest_latitude, dest_longitude)
        discounted_metered_fare = [metered_fare - discount, 0].max

        INITIAL_FARE + discounted_metered_fare
      end
    end
  end
end
