# frozen_string_literal: true

module DiscourseAi
  module AiBot
    class EntryPoint
      GPT4_ID = -110
      GPT3_5_TURBO_ID = -111
      CLAUDE_V2_ID = -112
      BOTS = [[GPT4_ID, "gpt4_bot"], [GPT3_5_TURBO_ID, "gpt3.5_bot"], [CLAUDE_V2_ID, "claude_bot"]]

      def self.map_bot_model_to_user_id(model_name)
        case model_name
        in "gpt-3.5-turbo"
          GPT3_5_TURBO_ID
        in "gpt-4"
          GPT4_ID
        in "claude-2"
          CLAUDE_V2_ID
        else
          nil
        end
      end

      def load_files
        require_relative "jobs/regular/create_ai_reply"
        require_relative "jobs/regular/update_ai_bot_pm_title"
        require_relative "bot"
        require_relative "anthropic_bot"
        require_relative "open_ai_bot"
        require_relative "commands/command"
        require_relative "commands/search_command"
        require_relative "commands/categories_command"
        require_relative "commands/tags_command"
        require_relative "commands/time_command"
        require_relative "commands/summarize_command"
        require_relative "commands/image_command"
        require_relative "commands/google_command"
        require_relative "commands/read_command"
      end

      def inject_into(plugin)
        plugin.register_seedfu_fixtures(
          Rails.root.join("plugins", "discourse-ai", "db", "fixtures", "ai_bot"),
        )

        plugin.add_to_serializer(
          :current_user,
          :ai_enabled_chat_bots,
          include_condition: -> do
            SiteSetting.ai_bot_enabled && scope.authenticated? &&
              scope.user.in_any_groups?(SiteSetting.ai_bot_allowed_groups_map)
          end,
        ) do
          model_map = {}
          SiteSetting
            .ai_bot_enabled_chat_bots
            .split("|")
            .each do |bot_name|
              model_map[
                ::DiscourseAi::AiBot::EntryPoint.map_bot_model_to_user_id(bot_name)
              ] = bot_name
            end

          # not 100% ideal, cause it is one extra query, but we need it
          bots = DB.query_hash(<<~SQL, user_ids: model_map.keys)
            SELECT username, id FROM users WHERE id IN (:user_ids)
          SQL

          bots.each { |hash| hash["model_name"] = model_map[hash["id"]] }
          bots
        end

        plugin.register_svg_icon("robot")

        plugin.on(:post_created) do |post|
          bot_ids = BOTS.map(&:first)

          if post.post_type == Post.types[:regular] && post.topic.private_message? &&
               !bot_ids.include?(post.user_id)
            if (SiteSetting.ai_bot_allowed_groups_map & post.user.group_ids).present?
              bot_id = post.topic.topic_allowed_users.where(user_id: bot_ids).first&.user_id

              if bot_id
                Jobs.enqueue(:create_ai_reply, post_id: post.id, bot_user_id: bot_id)
                Jobs.enqueue_in(
                  5.minutes,
                  :update_ai_bot_pm_title,
                  post_id: post.id,
                  bot_user_id: bot_id,
                )
              end
            end
          end
        end
      end
    end
  end
end
